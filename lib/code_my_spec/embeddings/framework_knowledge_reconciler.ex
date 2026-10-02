defmodule CodeMySpec.Embeddings.FrameworkKnowledgeReconciler do
  @moduledoc """
  Embeds `priv/knowledge` once, as shared rows, on server boot — step 4 of
  the embeddings rework (577de9bb).

  The corpus ships inside the release, so it only changes on release (or a
  dev restart). No watcher: boot hashes every file, diffs against what's
  stored, and embeds only what's missing or changed.

  ## Versioning

  Rows are `project_id NULL`, `package "code_my_spec"`, `source "knowledge"`,
  stamped with the serving's model. `version` is the corpus hash: a sha256
  over every file's relative path and content hash. One version per model
  is current at a time.

  ## Completeness

  The `doc_packages` marker for `(code_my_spec, corpus hash, model)`, same
  as hex docs. Vectors are computed first, outside any transaction; then one
  transaction swaps the corpus: delete changed/removed files' rows, re-stamp
  kept rows with the new version, insert the new chunks, replace the marker.
  A crash before commit leaves the previous corpus intact and unmarked work
  is redone on the next boot. A marker for the current hash means nothing
  to do, so a second boot embeds nothing.

  Search reads only the version the embedded marker names, so it sees
  exactly one complete corpus.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Embeddings.DocEmbedding
  alias CodeMySpec.Embeddings.DocPackage
  alias CodeMySpec.Embeddings.EmbeddingService
  alias CodeMySpec.Embeddings.PgVectorBackend
  alias CodeMySpec.Embeddings.Serving
  alias CodeMySpec.Repo

  @package "code_my_spec"
  @source "knowledge"
  @complete ~w(embedded no_docs)

  # Same cap as HexDocReconciler: bounds a search's wait to one batch.
  @bulk_batch_size 20
  @flame_timeout :timer.minutes(1)

  # Another server swapping the corpus between plan and commit.
  @max_plan_attempts 3

  @doc "The package name framework knowledge rows and markers carry."
  @spec package() :: String.t()
  def package, do: @package

  @doc "The release's knowledge dir; `:framework_knowledge_dir` overrides it in tests."
  @spec knowledge_dir() :: String.t()
  def knowledge_dir do
    Application.get_env(:code_my_spec, :framework_knowledge_dir) ||
      Application.app_dir(:code_my_spec, "priv/knowledge")
  end

  @doc "Boot child: one `reconcile_on_boot/0` in a `:temporary` Task."
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    Supervisor.child_spec({Task, &reconcile_on_boot/0}, id: __MODULE__, restart: :temporary)
  end

  @doc """
  Boot entry point. Never raises: a failure is logged and the next boot
  retries.
  """
  @spec reconcile_on_boot() :: :ok
  def reconcile_on_boot do
    case reconcile() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[FrameworkKnowledge] deferred to next boot: #{inspect(reason)}")
    end

    :ok
  rescue
    e ->
      Logger.error("[FrameworkKnowledge] " <> Exception.format(:error, e, __STACKTRACE__))
      :ok
  catch
    :exit, reason ->
      Logger.error("[FrameworkKnowledge] exited: #{inspect(reason)}")
      :ok
  end

  @doc """
  Bring the stored corpus in line with `knowledge_dir/0`.

  `{:ok, :up_to_date}` when the current hash is already marked complete,
  otherwise `{:ok, %{version, embedded, kept, removed, chunk_count}}`.
  """
  @spec reconcile() :: {:ok, :up_to_date | map()} | {:error, term()}
  def reconcile, do: reconcile(1)

  defp reconcile(attempt) do
    start_ms = System.monotonic_time(:millisecond)
    model = Serving.model_name()
    desired = desired_files(knowledge_dir())
    version = corpus_version(desired)

    if complete?(version, model) do
      {:ok, :up_to_date}
    else
      current = current_version(model)
      plan = plan(desired, stored_hashes(current, model))

      with {:ok, embedded} <- embed_all(chunk_entries(desired, plan.changed)),
           {:ok, result} <- swap(version, model, current, plan, embedded) do
        log_summary(result, start_ms)
        {:ok, result}
      else
        {:error, :stale_plan} when attempt < @max_plan_attempts -> reconcile(attempt + 1)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "`%{relative_path => {file_hash, content}}` for every markdown file in `dir`."
  @spec desired_files(String.t()) :: %{String.t() => {String.t(), String.t()}}
  def desired_files(dir) do
    dir
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn abs ->
      content = File.read!(abs)
      {Path.relative_to(abs, dir), {EmbeddingService.content_hash(content), content}}
    end)
  end

  @doc "Hash of the whole corpus: stable under file order, changes with any path or content."
  @spec corpus_version(map()) :: String.t()
  def corpus_version(desired) do
    desired
    |> Enum.map(fn {path, {hash, _content}} -> path <> "\0" <> hash end)
    |> Enum.sort()
    |> Enum.join("\n")
    |> EmbeddingService.content_hash()
  end

  @doc "The version of the complete corpus at `model`, if any."
  @spec current_version(String.t()) :: String.t() | nil
  def current_version(model) do
    from(p in DocPackage,
      where: p.package == @package and p.model == ^model and p.status in @complete,
      order_by: [desc: p.updated_at],
      limit: 1,
      select: p.version
    )
    |> Repo.one()
  end

  defp complete?(version, model) do
    Repo.exists?(
      from(p in DocPackage,
        where:
          p.package == @package and p.version == ^version and p.model == ^model and
            p.status in @complete
      )
    )
  end

  defp stored_hashes(nil, _model), do: %{}

  defp stored_hashes(version, model) do
    from(e in shared_rows(model),
      where: e.version == ^version,
      distinct: true,
      select: {e.path, e.file_hash}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp shared_rows(model) do
    from(e in DocEmbedding,
      where:
        is_nil(e.project_id) and e.package == @package and e.source == @source and
          e.model == ^model
    )
  end

  defp plan(desired, stored) do
    {kept, changed} =
      desired
      |> Map.keys()
      |> Enum.split_with(fn path -> Map.get(stored, path) == elem(desired[path], 0) end)

    %{kept: kept, changed: changed, removed: Map.keys(stored) -- Map.keys(desired)}
  end

  defp chunk_entries(desired, paths) do
    Enum.flat_map(paths, fn path ->
      {file_hash, content} = desired[path]

      content
      |> EmbeddingService.chunk_text()
      |> Enum.with_index()
      |> Enum.map(fn {chunk, index} -> {path, index, chunk, file_hash} end)
    end)
  end

  defp embed_all(entries) do
    entries
    |> Enum.chunk_every(@bulk_batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case embed_batch(batch) do
        {:ok, vectors} -> {:cont, {:ok, acc ++ Enum.zip(batch, vectors)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp embed_batch(batch) do
    texts = Enum.map(batch, fn {_path, _index, chunk, _file_hash} -> chunk end)

    FLAME.call(CodeMySpec.EmbedPool, fn -> Serving.embed_batch(texts, :bulk) end,
      timeout: @flame_timeout
    )
  end

  defp swap(version, model, planned_current, plan, embedded) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext('framework_knowledge_reconcile'))")

      cond do
        complete?(version, model) -> Repo.rollback(:already_done)
        current_version(model) != planned_current -> Repo.rollback(:stale_plan)
        true -> write_corpus(version, model, planned_current, plan, embedded)
      end
    end)
    |> case do
      {:error, :already_done} -> {:ok, :up_to_date}
      other -> other
    end
  end

  defp write_corpus(version, model, current, plan, embedded) do
    prune(model, current, plan.kept)
    restamp(model, current, version, plan.kept)

    with :ok <- insert_chunks(version, model, embedded),
         chunk_count = count_rows(version, model),
         {:ok, _} <- mark(version, model, chunk_count) do
      %{
        version: version,
        embedded: length(plan.changed),
        kept: length(plan.kept),
        removed: length(plan.removed),
        chunk_count: chunk_count
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Everything at this model except the kept files' rows of the current version.
  defp prune(model, nil, _kept), do: Repo.delete_all(shared_rows(model))

  defp prune(model, current, kept) do
    from(e in shared_rows(model), where: not (e.version == ^current and e.path in ^kept))
    |> Repo.delete_all()
  end

  defp restamp(_model, nil, _version, _kept), do: :ok

  defp restamp(model, current, version, kept) do
    from(e in shared_rows(model), where: e.version == ^current and e.path in ^kept)
    |> Repo.update_all(set: [version: version])
  end

  defp insert_chunks(version, model, embedded) do
    Enum.reduce_while(embedded, :ok, fn {{path, index, chunk, file_hash}, vector}, :ok ->
      case PgVectorBackend.store_embedded_chunk(
             nil,
             @source,
             path,
             index,
             chunk,
             file_hash,
             vector,
             package: @package,
             version: version,
             model: model
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp count_rows(version, model) do
    Repo.aggregate(from(e in shared_rows(model), where: e.version == ^version), :count)
  end

  defp mark(version, model, chunk_count) do
    from(p in DocPackage,
      where: p.package == @package and p.model == ^model and p.version != ^version
    )
    |> Repo.delete_all()

    status = if chunk_count == 0, do: "no_docs", else: "embedded"

    %DocPackage{}
    |> DocPackage.changeset(%{
      package: @package,
      version: version,
      model: model,
      status: status,
      chunk_count: chunk_count,
      embedded_at: DateTime.truncate(DateTime.utc_now(), :second)
    })
    |> Repo.insert(
      on_conflict: {:replace, [:status, :chunk_count, :error, :embedded_at, :updated_at]},
      conflict_target: [:package, :version, :model]
    )
  end

  defp log_summary(:up_to_date, _start_ms), do: :ok

  defp log_summary(summary, start_ms) do
    elapsed_ms = System.monotonic_time(:millisecond) - start_ms

    Logger.info(
      "[FrameworkKnowledge] #{String.slice(summary.version, 0, 12)}: " <>
        "#{summary.embedded} embedded, #{summary.kept} kept, #{summary.removed} removed, " <>
        "#{summary.chunk_count} chunks in #{elapsed_ms}ms"
    )
  end
end
