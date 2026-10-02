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
  pinned, parse its `.ex` sources with `HexDocProjector`'s pure functions,
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
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Dependencies.Dependency
  alias CodeMySpec.Embeddings.DocPackage
  alias CodeMySpec.Embeddings.EmbeddingService
  alias CodeMySpec.Embeddings.HexDocProjector
  alias CodeMySpec.Embeddings.HexPackageFetch
  alias CodeMySpec.Embeddings.HexTarball
  alias CodeMySpec.Embeddings.PgVectorBackend
  alias CodeMySpec.Embeddings.Serving
  alias CodeMySpec.Repo

  @bulk_batch_size 20

  @doc """
  Every `{name, version, checksum}` a project depends on from hex that has
  no `doc_packages` row at the currently-configured model — deduplicated
  across projects, since the same package@version pinned by two projects is
  one piece of work, not two.
  """
  @spec pending() :: [%{name: String.t(), version: String.t(), checksum: String.t() | nil}]
  def pending do
    model = Serving.model_name()

    from(d in Dependency,
      where: d.source == "hex",
      left_join: p in DocPackage,
      on: p.package == d.name and p.version == d.version and p.model == ^model,
      where: is_nil(p.id),
      distinct: [d.name, d.version],
      select: %{name: d.name, version: d.version, checksum: d.checksum}
    )
    |> Repo.all()
  end

  @doc "Reconcile every pending package@version. Best-effort: one failure doesn't stop the rest."
  @spec reconcile_all() :: :ok
  def reconcile_all do
    pending()
    |> Enum.each(&reconcile_one/1)
  end

  defp reconcile_one(%{name: name, version: version, checksum: checksum}) do
    FLAME.call(CodeMySpec.EmbedPool, fn -> do_reconcile(name, version, checksum) end)
  rescue
    e ->
      Logger.error(
        "[HexDocReconciler] #{name}@#{version}: " <> Exception.format(:error, e, __STACKTRACE__)
      )

      mark_failed(name, version, Exception.format(:error, e, __STACKTRACE__))
  end

  defp do_reconcile(name, version, checksum) do
    with {:ok, tarball} <- HexPackageFetch.fetch(name, version, checksum),
         {:ok, sources} <- HexTarball.ex_sources(tarball) do
      embed_package(name, version, sources)
    else
      {:error, reason} ->
        Logger.warning("[HexDocReconciler] #{name}@#{version} failed: #{inspect(reason)}")
        mark_failed(name, version, inspect(reason))
    end
  end

  defp embed_package(name, version, sources) do
    docs =
      sources
      |> Map.values()
      |> Enum.flat_map(&HexDocProjector.docs_from_source/1)

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

    case embed_all(entries) do
      {:ok, embedded} ->
        store_and_mark(name, version, model, source, embedded)

      {:error, reason} ->
        Logger.warning("[HexDocReconciler] #{name}@#{version} embedding failed: #{inspect(reason)}")
        mark_failed(name, version, inspect(reason))
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

  defp store_and_mark(name, version, model, source, embedded) do
    Repo.transaction(fn ->
      Enum.each(embedded, fn {{path, index, chunk, file_hash}, embedding} ->
        :ok =
          PgVectorBackend.store_embedded_chunk(
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
          )
      end)

      case mark_in_transaction(name, version, model, "embedded", chunk_count: length(embedded)) do
        {:ok, doc_package} -> doc_package
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark(name, version, status, attrs) do
    model = Serving.model_name()

    case mark_in_transaction(name, version, model, status, attrs) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("[HexDocReconciler] could not mark #{name}@#{version}: #{inspect(reason)}")
        :ok
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
      on_conflict: {:replace, [:status, :chunk_count, :error, :embedded_at, :updated_at]},
      conflict_target: [:package, :version, :model]
    )
  end
end
