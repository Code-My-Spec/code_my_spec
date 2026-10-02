defmodule CodeMySpec.Embeddings.HexDocReconciler do
  @moduledoc """
  Embeds a hex package's docs once, server-side, for every project that
  depends on it — the step 3 half of the embeddings rework (577de9bb).

  `project_dependencies` records what's pinned (step 3's own trigger,
  `Files.FileSync.reconcile_lockfile/1`, keeps it current from each
  project's main copy's `mix.lock`); `doc_packages` records what's
  embedded. This is the convergence between the two: for every
  `{package, version}` no project's `doc_packages` row has reached yet,
  fetch the hex.pm tarball, verify it against the checksum the lock itself
  pinned, parse its `.ex` sources with `HexDocParser`,
  chunk and embed each module's docs, and write the `doc_packages` marker
  last — in the same transaction as the final chunk, so "present" means
  "complete" even across a crash mid-package.

  One `FLAME.call` per package@version, not per project: many projects
  commonly pin the same package at the same version, and the embedding is
  a property of `(package, version, model)`, never of any one project — the
  same reasoning `doc_embeddings`' shared rows already follow for framework
  knowledge.

  Capped at `@bulk_batch_size` chunks per `Serving.embed_batch/2` call. The
  serving's own queue can't preempt a job already dispatched to its worker
  (see `OrtexServing`'s moduledoc), so a package with hundreds of chunks
  embedded as one call would make a pending search wait behind the whole
  thing; slicing into capped calls bounds that wait to one small batch.

  ## Deterministic failures are recorded once; everything else is retried,
  ## bounded

  Every step from the fetch down to the final chunk insert resolves to
  `{:ok, _} | {:error, reason}` — never a raise, which is what lets the
  two outcomes below actually happen instead of a crash deciding for them.

    * **Terminal** — a 404 (the version was never published, so it's
      `no_docs`), a checksum mismatch, an unparseable tarball, any other
      HTTP status: the request got a real, final answer, and asking again
      would get the same one. Recorded as one `doc_packages` row (`failed`
      or `no_docs`), which `pending/0`'s "no row yet" check then excludes
      from every later sweep — no separate retry bookkeeping.
    * **Deferred** — a closed connection, a timeout, hex.pm's own 5xx, a
      failure embedding or storing: none of these say anything about the
      package's *content*, only that something was unreachable or busy
      just now. Recorded as `status: "pending"` with an incremented
      `attempts`, which `pending/0` keeps offering up to `@max_attempts`
      — bounded, unlike leaving no row at all, which is what the first cut
      of this module did and which cannot tell "will recover on its own"
      from "hangs identically on every single attempt". Past the cap, a
      deferred failure becomes a terminal `failed` one.

  Found live: the first real sweep went silent for 40+ minutes with no
  log line anywhere, because `Task.async_stream`'s killed-on-timeout task
  produces an `{:exit, reason}` in the result stream that nothing was
  reading — not a raise `reconcile_one/1`'s `rescue` could see, not a
  return value `defer/3` could record. `reconcile_all/0` now reads that
  stream instead of discarding it, logs one summary line per sweep
  (pending count, outcome tally, duration), and `FLAME.call`'s own
  timeout is explicit and shorter than the stream's, so a wedged package
  gets FLAME's clean `{:error, _}` before the stream's blunter kill ever
  has to fire.

  `reconcile_one/1` still carries a `rescue` around the whole thing — not
  the normal failure path (every modeled failure above already resolves
  without raising), but the last line against a genuinely unanticipated
  crash, which it marks `failed` rather than swallowing silently: unlike
  a deferred failure, an unknown one deserves a human looking at why
  before it's retried.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Dependencies.Dependency
  alias CodeMySpec.Embeddings.DocPackage
  alias CodeMySpec.Embeddings.EmbeddingService
  alias CodeMySpec.Embeddings.HexDocParser
  alias CodeMySpec.Embeddings.HexPackageFetch
  alias CodeMySpec.Embeddings.HexTarball
  alias CodeMySpec.Embeddings.PgVectorBackend
  alias CodeMySpec.Embeddings.Serving
  alias CodeMySpec.Repo

  @bulk_batch_size 20

  # Matches `CodeMySpec.EmbedPool`'s own `max: 4` (application.ex). Fetching
  # and parsing a tarball is genuinely parallel work; the actual embedding
  # still serializes through `OrtexServing`'s one worker regardless of how
  # many packages are in flight here, which is what keeps a concurrent
  # search's wait bounded by `@bulk_batch_size`, not by this number.
  @max_concurrency 4

  # How many deferred attempts a package gets before a failure that says
  # nothing deterministic becomes terminal anyway. Without a cap, a
  # package that hangs or errors identically on every attempt — not a
  # genuine transient blip — would retry forever, burning a concurrency
  # slot every sweep.
  @max_attempts 3

  # FLAME's own call timeout, explicit rather than the pool's 30s default:
  # a package with a hundred-plus chunks spends real time in
  # `OrtexServing`'s one worker, and 30s was tight enough to plausibly
  # defer large packages on nothing more than their own size.
  @flame_timeout :timer.minutes(3)

  # Always longer than `@flame_timeout`, so FLAME's own deadline produces
  # a clean `{:error, _}` first in the ordinary case; this is the hard
  # backstop for whatever FLAME's timeout cannot reach — a stuck NIF call
  # blocking its scheduler thread is the one failure mode nothing short of
  # killing the task (or the node) can interrupt.
  @task_timeout :timer.minutes(4)

  @doc """
  Every `{name, version, checksum}` a project depends on from hex that
  either has no `doc_packages` row at the currently-configured model, or
  has one still `status: "pending"` with attempts left — deduplicated
  across projects, since the same package@version pinned by two projects
  is one piece of work, not two.
  """
  @spec pending() :: [%{name: String.t(), version: String.t(), checksum: String.t() | nil}]
  def pending do
    model = Serving.model_name()

    from(d in Dependency,
      where: d.source == "hex",
      left_join: p in DocPackage,
      on: p.package == d.name and p.version == d.version and p.model == ^model,
      where: is_nil(p.id) or (p.status == "pending" and p.attempts < @max_attempts),
      distinct: [d.name, d.version],
      select: %{name: d.name, version: d.version, checksum: d.checksum}
    )
    |> Repo.all()
  end

  @doc """
  Puts `failed` markers at the current model back to `pending` with no
  attempts and no error, so the next sweep tries them again. For failures
  whose cause has since been fixed — a terminal marker is otherwise final.

  Options narrow which: `:packages` (only these names), `:except` (not
  these names), `:error_like` (only markers whose error contains this
  text, e.g. `"unique_violation"`). Returns how many were reset.
  """
  @spec reset_failed(keyword()) :: non_neg_integer()
  def reset_failed(opts \\ []) do
    model = Serving.model_name()

    {count, _} =
      from(p in DocPackage, where: p.status == "failed" and p.model == ^model)
      |> only_packages(Keyword.get(opts, :packages))
      |> except_packages(Keyword.get(opts, :except))
      |> error_like(Keyword.get(opts, :error_like))
      |> Repo.update_all(
        set: [
          status: "pending",
          attempts: 0,
          error: nil,
          updated_at: DateTime.truncate(DateTime.utc_now(), :second)
        ]
      )

    count
  end

  defp only_packages(query, names) when is_list(names) and names != [],
    do: where(query, [p], p.package in ^names)

  defp only_packages(query, _names), do: query

  defp except_packages(query, names) when is_list(names) and names != [],
    do: where(query, [p], p.package not in ^names)

  defp except_packages(query, _names), do: query

  defp error_like(query, text) when is_binary(text) and text != "",
    do: where(query, [p], like(p.error, ^"%#{text}%"))

  defp error_like(query, _text), do: query

  @doc """
  Reconcile every pending package@version, up to `@max_concurrency` at
  once. Best-effort: one failure doesn't stop the rest. Logs one summary
  line — pending count, outcome tally, duration — so a sweep that stalls
  is visible from the log the moment it happens, not discovered by
  noticing `doc_packages` stopped moving.
  """
  @spec reconcile_all() :: :ok
  def reconcile_all do
    start_ms = System.monotonic_time(:millisecond)
    items = pending()

    outcomes =
      items
      |> Task.async_stream(&reconcile_one/1,
        max_concurrency: @max_concurrency,
        timeout: @task_timeout,
        on_timeout: :kill_task
      )
      |> Enum.zip(items)
      |> Enum.map(&resolve_outcome/1)

    elapsed_ms = System.monotonic_time(:millisecond) - start_ms

    Logger.info(
      "[HexDocReconciler] sweep: #{length(items)} pending, " <>
        "#{inspect(Enum.frequencies(outcomes))} in #{elapsed_ms}ms"
    )

    :ok
  end

  defp resolve_outcome({{:ok, outcome}, _item}), do: outcome

  # The one result `Task.async_stream` itself can produce without ever
  # calling `reconcile_one/1`'s body again: the task was killed for
  # running past `@task_timeout`. Routed through the same `defer/3` every
  # other retryable failure uses, so it counts against the same attempt
  # cap instead of retrying forever.
  defp resolve_outcome({{:exit, reason}, %{name: name, version: version}}) do
    Logger.warning(
      "[HexDocReconciler] #{name}@#{version} killed after #{@task_timeout}ms: #{inspect(reason)}"
    )

    defer(name, version, {:task_killed, reason})
  end

  defp reconcile_one(%{name: name, version: version, checksum: checksum}) do
    FLAME.call(
      CodeMySpec.EmbedPool,
      fn -> do_reconcile(name, version, checksum) end,
      timeout: @flame_timeout
    )
  rescue
    e ->
      Logger.error(
        "[HexDocReconciler] #{name}@#{version}: " <> Exception.format(:error, e, __STACKTRACE__)
      )

      mark_failed(name, version, Exception.format(:error, e, __STACKTRACE__))
      :crashed
  end

  defp do_reconcile(name, version, checksum) do
    with {:ok, tarball} <- HexPackageFetch.fetch(name, version, checksum),
         {:ok, sources} <- HexTarball.ex_sources(tarball) do
      embed_package(name, version, sources)
    else
      {:error, reason} -> handle_fetch_failure(name, version, reason)
    end
  end

  # A 404 means this exact version was never published (or was retracted)
  # — deterministic, so it's recorded the same way a genuinely undocumented
  # package is: nothing to embed, nothing to gain by asking again.
  defp handle_fetch_failure(name, version, {:http_status, 404}) do
    Logger.info("[HexDocReconciler] #{name}@#{version}: 404, no docs published at this version")
    mark(name, version, "no_docs", chunk_count: 0)
  end

  # hex.pm's own trouble, not this package's — stays retryable.
  defp handle_fetch_failure(name, version, {:http_status, status}) when status >= 500 do
    defer(name, version, {:http_status, status})
  end

  # Any other HTTP status (auth, rate limit, redirect loop, ...) is treated
  # as deterministic for this exact request, same reasoning as a checksum
  # mismatch: retrying the identical request won't change hex.pm's answer.
  defp handle_fetch_failure(name, version, {:http_status, status}) do
    mark_failed(name, version, "http_status_#{status}")
  end

  defp handle_fetch_failure(name, version, reason)
       when reason in [:checksum_mismatch, :no_checksum] do
    mark_failed(name, version, to_string(reason))
  end

  defp handle_fetch_failure(name, version, {tag, _} = reason)
       when tag in [:outer_tar, :inner_tar, :gunzip, :missing_entry] do
    mark_failed(name, version, inspect(reason))
  end

  # Everything else — a closed connection, a timeout, DNS, any other
  # transport-level failure `Req` can raise — says nothing about this
  # package's content, only that hex.pm couldn't be reached just now.
  defp handle_fetch_failure(name, version, reason), do: defer(name, version, reason)

  # Retryable, but bounded: `attempts` is read off whatever row already
  # exists (none yet means 0) and written back incremented, which is what
  # lets `pending/0` keep offering this package up to `@max_attempts` —
  # past that, a failure that keeps recurring identically stops being
  # "probably transient" and gets recorded as `failed` instead.
  defp defer(name, version, reason) do
    Logger.warning(
      "[HexDocReconciler] #{name}@#{version} deferred (retryable): #{inspect(reason)}"
    )

    model = Serving.model_name()
    attempts = current_attempts(name, version, model) + 1

    if attempts >= @max_attempts do
      Logger.warning(
        "[HexDocReconciler] #{name}@#{version} exhausted #{attempts} attempts, marking failed"
      )

      mark_failed(name, version, "exhausted #{attempts} attempts: " <> inspect(reason))
    else
      mark(name, version, "pending", attempts: attempts, error: inspect(reason))
      :deferred
    end
  end

  defp current_attempts(name, version, model) do
    case Repo.get_by(DocPackage, package: name, version: version, model: model) do
      %DocPackage{attempts: attempts} when is_integer(attempts) -> attempts
      _ -> 0
    end
  end

  defp embed_package(name, version, sources) do
    docs =
      sources
      |> Map.values()
      |> Enum.flat_map(&HexDocParser.docs_from_source/1)
      # A module documented from more than one source file (seen live:
      # bandit's Bandit.Clock) would otherwise chunk and store under the
      # same path twice, tripping the identity index's own uniqueness on
      # the second write. First occurrence wins — deterministic, and which
      # file "owns" the docs is not a distinction this pipeline needs to
      # make.
      |> Enum.uniq_by(fn {module_name, _markdown} -> module_name end)

    entries = Enum.flat_map(docs, &chunk_entries/1)
    embed_and_store(name, version, entries)
  end

  # One module's markdown, split into `{path, index, chunk, file_hash}`
  # entries ready to embed. `file_hash` is the whole module's own hash —
  # there is no incremental "did this module change" check here, unlike
  # `EmbeddingService.embed_file/4`: a package@version is embedded exactly
  # once, ever, gated by `pending/0` finding no `doc_packages` row at all.
  defp chunk_entries({module_name, markdown}) do
    file_hash = EmbeddingService.content_hash(markdown)
    path = "#{module_name}.md"

    markdown
    |> EmbeddingService.chunk_text()
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} -> {path, index, chunk, file_hash} end)
  end

  defp embed_and_store(name, version, []) do
    mark(name, version, "no_docs", chunk_count: 0)
  end

  defp embed_and_store(name, version, entries) do
    source = "hexdocs:#{name}"
    model = Serving.model_name()

    # Deferred, not failed: neither embedding nor storage says anything
    # about this package's own content — a failure here is the serving or
    # the database having trouble right now, which the next sweep is
    # exactly as likely to find recovered.
    with {:ok, embedded} <- embed_all(entries),
         {:ok, :embedded} <- store_and_mark(name, version, model, source, embedded) do
      :embedded
    else
      {:error, reason} -> defer(name, version, reason)
    end
  end

  # Embeds in capped batches so no single `Serving.embed_batch/2` call holds
  # the one worker for longer than `@bulk_batch_size` chunks — see moduledoc.
  defp embed_all(entries) do
    entries
    |> Enum.chunk_every(@bulk_batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      texts = Enum.map(batch, fn {_path, _index, chunk, _file_hash} -> chunk end)

      case Serving.embed_batch(texts, :bulk) do
        {:ok, vectors} ->
          {:cont, {:ok, acc ++ Enum.zip(batch, vectors)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # Any ordinary failure here — including the unique-violation two
  # concurrent attempts at the same package@version would race into, since
  # nothing claims a package as "in progress" before starting it — has to
  # come back as `{:error, _}`, never a raised exception. A raise rolls the
  # transaction back exactly the same way `Repo.rollback/1` does, but
  # leaves nothing for `embed_and_store/3` to catch: the package stays
  # pending forever instead of landing a recorded `failed` marker, which is
  # the one outcome `pending/0`'s "no doc_packages row yet" check cannot
  # tell apart from "never attempted".
  defp store_and_mark(name, version, model, source, embedded) do
    Repo.transaction(fn ->
      with :ok <- store_all_chunks(name, version, model, source, embedded),
           {:ok, doc_package} <-
             mark_in_transaction(name, version, model, "embedded", chunk_count: length(embedded)) do
        doc_package
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, _} -> {:ok, :embedded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp store_all_chunks(name, version, model, source, embedded) do
    Enum.reduce_while(embedded, :ok, fn {{path, index, chunk, file_hash}, embedding}, :ok ->
      case PgVectorBackend.store_embedded_chunk(
             nil,
             source,
             path,
             index,
             chunk,
             file_hash,
             embedding,
             package: name,
             version: version,
             model: model
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mark(name, version, status, attrs) do
    model = Serving.model_name()

    case mark_in_transaction(name, version, model, status, attrs) do
      {:ok, _} ->
        String.to_existing_atom(status)

      {:error, reason} ->
        Logger.error("[HexDocReconciler] could not mark #{name}@#{version}: #{inspect(reason)}")
        :mark_error
    end
  end

  defp mark_failed(name, version, error) do
    mark(name, version, "failed", error: error, chunk_count: 0)
  end

  defp mark_in_transaction(name, version, model, status, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changeset_attrs =
      %{
        package: name,
        version: version,
        model: model,
        status: status,
        embedded_at: now
      }
      |> Map.merge(Map.new(attrs))

    %DocPackage{}
    |> DocPackage.changeset(changeset_attrs)
    |> Repo.insert(
      on_conflict:
        {:replace, [:status, :chunk_count, :error, :embedded_at, :attempts, :updated_at]},
      conflict_target: [:package, :version, :model]
    )
  end
end
