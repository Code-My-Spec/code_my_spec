defmodule CodeMySpec.Embeddings.HexDocReconciler do
  @moduledoc """
  Embeds a hex package's docs once, server-side, for every project that
  depends on it.

  `project_dependencies` records what's pinned (kept current by
  `Files.FileSync.reconcile_lockfile/2` from each project's main copy's
  `mix.lock`); `doc_packages` records what's embedded. For every
  `{package, version}` with no finished `doc_packages` row at the current
  model, this fetches the hex.pm tarball, verifies it against the lock's
  checksum, parses its `.ex` sources with `HexDocParser`, chunks and embeds
  each module's docs, and writes the `doc_packages` marker in the same
  transaction as the chunks — "present" means "complete", even across a
  crash.

  One `EmbedPool` call per package@version, not per project: the embedding is
  a property of `(package, version, model)`, never of a project.

  Capped at `@bulk_batch_size` chunks per `Serving.embed_batch/2` call: the
  serving cannot preempt a dispatched job (see `OrtexServing`), so capped
  calls bound how long a pending search waits.

  ## Terminal failures are recorded once; the rest retry, bounded

  Every step resolves to `{:ok, _} | {:error, reason}`, never a raise.

    * **Terminal** — a 404 (`no_docs`), a checksum mismatch, an unparseable
      tarball, any other non-5xx HTTP status: asking again gets the same
      answer. One `doc_packages` row (`failed` or `no_docs`), which
      `pending/0` then excludes.
    * **Deferred** — a transport failure, a timeout, hex.pm's 5xx, an
      embedding or storage failure: nothing about the package's content.
      Recorded as `status: "pending"` with `attempts` incremented;
      `pending/0` offers it until `@max_attempts`, then it becomes `failed`.

  `reconcile_all/0` reads `Task.async_stream`'s `{:exit, _}` results (a task
  killed at `@task_timeout`) and defers them, and logs one summary line per
  sweep. The pool call's timeout is shorter than the stream's, so a wedged
  package usually gets a clean `{:error, _}` first. `reconcile_one/1`'s
  `rescue` is the last line against an unanticipated crash, marked `failed`
  so a human looks before it retries.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Dependencies.Dependency
  alias CodeMySpec.Embeddings.DocPackage
  alias CodeMySpec.Embeddings.EmbeddingService
  alias CodeMySpec.Embeddings.HexDocParser
  alias CodeMySpec.Embeddings.HexPackageFetch
  alias CodeMySpec.Embeddings.HexTarball
  alias CodeMySpec.Embeddings.InFlightCalls
  alias CodeMySpec.Embeddings.PgVectorBackend
  alias CodeMySpec.Embeddings.Serving
  alias CodeMySpec.Repo

  @bulk_batch_size 20

  # Matches `CodeMySpec.EmbedPool`'s `max: 4`. Embedding still serializes
  # through `OrtexServing`'s one worker; this only parallelizes fetch/parse.
  @max_concurrency 4

  # Deferred attempts before a failure becomes terminal, so a package that
  # fails identically every time stops taking a slot every sweep.
  @max_attempts 3

  # Explicit, not the pool's 30s default: a large package spends real time in
  # `OrtexServing`'s one worker.
  @flame_timeout :timer.minutes(3)

  # Longer than `@flame_timeout`, so the pool's deadline fires first; this is
  # the backstop for what it cannot interrupt (a stuck NIF call).
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
      select: %{name: d.name, version: d.version, checksum: d.checksum}
    )
    |> Repo.all()
    |> Enum.uniq_by(&{&1.name, &1.version})
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
  line — pending count, outcome tally, duration — so a stalled sweep is
  visible in the log.
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

  # A task killed at `@task_timeout`. Deferred like any retryable failure, so
  # it counts against the same attempt cap.
  defp resolve_outcome({{:exit, reason}, %{name: name, version: version}}) do
    Logger.warning(
      "[HexDocReconciler] #{name}@#{version} killed after #{@task_timeout}ms: #{inspect(reason)}"
    )

    defer(name, version, {:task_killed, reason})
  end

  defp reconcile_one(%{name: name, version: version, checksum: checksum}) do
    InFlightCalls.call(
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

  # This version was never published (or was retracted): deterministic.
  defp handle_fetch_failure(name, version, {:http_status, 404}) do
    Logger.info("[HexDocReconciler] #{name}@#{version}: 404, no docs published at this version")
    mark(name, version, "no_docs", chunk_count: 0)
  end

  # hex.pm's own trouble, not this package's — stays retryable.
  defp handle_fetch_failure(name, version, {:http_status, status}) when status >= 500 do
    defer(name, version, {:http_status, status})
  end

  # Any other status (auth, rate limit, redirect loop): retrying the identical
  # request won't change hex.pm's answer.
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

  # Any other transport failure says nothing about the package's content.
  defp handle_fetch_failure(name, version, reason), do: defer(name, version, reason)

  # `attempts` is read off the existing row (none means 0) and written back
  # incremented; at `@max_attempts` the failure is recorded as `failed`.
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
      # A module documented from more than one source file would store under
      # the same path twice and trip the identity index. First one wins.
      |> Enum.uniq_by(fn {module_name, _markdown} -> module_name end)

    entries = Enum.flat_map(docs, &chunk_entries/1)
    embed_and_store(name, version, entries)
  end

  # One module's markdown, split into `{path, index, chunk, file_hash}`
  # entries. `file_hash` is the whole module's: a package@version is embedded
  # once, so there is no per-module change check.
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

    # Deferred, not failed: the serving or the database had trouble, not the
    # package's content.
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

  # Failures return `{:error, _}`, never raise, so `embed_and_store/3` can
  # defer them — including the unique violation two concurrent attempts at one
  # package@version race into (nothing claims a package in progress).
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
