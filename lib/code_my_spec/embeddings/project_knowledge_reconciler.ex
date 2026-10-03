defmodule CodeMySpec.Embeddings.ProjectKnowledgeReconciler do
  @moduledoc """
  A project's `.code_my_spec/knowledge` rows, reconciled against the
  fingerprints its main copy's `files` rows carry — step 5 of the embeddings
  rework (577de9bb).

  Rows are `project_id` set, `source "project_knowledge"`, keyed by the
  working-tree path, `package`/`version` NULL, stamped with the serving's
  model and `file_hash` = sha256 of the content embedded (the same hash the
  scanner fingerprints with).

  A path is current when every row for it carries the desired fingerprint at
  the current model. Anything else is re-read, re-embedded and replaced in one
  transaction; a path with no desired entry has its rows deleted. A path whose
  fingerprint is nil (the scan could not read it) is left alone.

  The server holds no content, so the caller supplies `read`. A failed read
  stops the pass: nothing is written for that file or any after it, nothing
  is deleted, and the next pass computes the same plan again.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Embeddings.DocEmbedding
  alias CodeMySpec.Embeddings.EmbeddingService
  alias CodeMySpec.Embeddings.InFlightCalls
  alias CodeMySpec.Embeddings.PgVectorBackend
  alias CodeMySpec.Embeddings.Serving
  alias CodeMySpec.Repo

  @source "project_knowledge"

  # Same cap as the hex and framework reconcilers: bounds a search's wait.
  @bulk_batch_size 20
  @flame_timeout :timer.minutes(1)

  @type desired :: %{String.t() => String.t() | nil}
  @type reader :: (String.t() -> {:ok, String.t()} | {:error, term()})

  @doc "The `source` project knowledge rows carry."
  @spec source() :: String.t()
  def source, do: @source

  @doc """
  Bring `project_id`'s rows in line with `desired` (`%{path => fingerprint}`).

  `{:ok, %{embedded, removed, kept}}` when every changed file landed;
  `{:error, {:deferred, reason}, partial}` when a read or embed failed part
  way — files before it are written, the rest stay pending.
  """
  @spec reconcile(Ecto.UUID.t(), desired(), reader()) ::
          {:ok, map()} | {:error, {:deferred, term()}, map()}
  def reconcile(project_id, desired, read) when is_map(desired) and is_function(read, 1) do
    model = Serving.model_name()
    plan = plan(desired, stored(project_id), model)

    removed = delete_paths(project_id, plan.removed)

    plan.changed
    |> Enum.reduce_while({:ok, 0}, fn path, {:ok, n} ->
      case refresh(project_id, path, read, model) do
        :ok -> {:cont, {:ok, n + 1}}
        {:error, reason} -> {:halt, {:error, reason, n}}
      end
    end)
    |> case do
      {:ok, n} ->
        {:ok, summary(n, removed, plan)}

      {:error, reason, n} ->
        {:error, {:deferred, reason}, summary(n, removed, plan)}
    end
  end

  defp summary(embedded, removed, plan),
    do: %{embedded: embedded, removed: removed, kept: length(plan.kept)}

  # `%{path => MapSet{{file_hash, model}}}` for this project's rows.
  defp stored(project_id) do
    from(e in DocEmbedding,
      where: e.project_id == ^project_id and e.source == @source,
      distinct: true,
      select: {e.path, e.file_hash, e.model}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_path, hash, model} -> {hash, model} end)
    |> Map.new(fn {path, pairs} -> {path, MapSet.new(pairs)} end)
  end

  defp plan(desired, stored, model) do
    {kept, changed} =
      desired
      |> Enum.reject(fn {_path, fingerprint} -> is_nil(fingerprint) end)
      |> Enum.sort()
      |> Enum.split_with(fn {path, fingerprint} ->
        Map.get(stored, path) == MapSet.new([{fingerprint, model}])
      end)

    %{
      kept: Enum.map(kept, &elem(&1, 0)),
      changed: Enum.map(changed, &elem(&1, 0)),
      removed: Map.keys(stored) -- Map.keys(desired)
    }
  end

  defp delete_paths(_project_id, []), do: 0

  defp delete_paths(project_id, paths) do
    {_count, _} = Repo.delete_all(rows(project_id, paths))
    length(paths)
  end

  defp rows(project_id, paths) do
    from(e in DocEmbedding,
      where: e.project_id == ^project_id and e.source == @source and e.path in ^paths
    )
  end

  defp refresh(project_id, path, read, model) do
    with {:ok, content} <- read.(path),
         file_hash = EmbeddingService.content_hash(content),
         chunks = EmbeddingService.chunk_text(content),
         {:ok, vectors} <- embed_all(chunks) do
      replace(project_id, path, file_hash, model, Enum.zip(chunks, vectors))
    end
  end

  defp embed_all(chunks) do
    chunks
    |> Enum.chunk_every(@bulk_batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case embed_batch(batch) do
        {:ok, vectors} -> {:cont, {:ok, acc ++ vectors}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp embed_batch(texts) do
    InFlightCalls.call(CodeMySpec.EmbedPool, fn -> Serving.embed_batch(texts, :bulk) end,
      timeout: @flame_timeout
    )
  catch
    :exit, reason -> {:error, {:embed_exit, reason}}
  end

  defp replace(project_id, path, file_hash, model, embedded) do
    Repo.transaction(fn ->
      Repo.delete_all(rows(project_id, [path]))

      embedded
      |> Enum.with_index()
      |> Enum.each(fn {{chunk, vector}, index} ->
        :ok = store(project_id, path, index, chunk, file_hash, vector, model)
      end)
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp store(project_id, path, index, chunk, file_hash, vector, model) do
    case PgVectorBackend.store_embedded_chunk(
           project_id,
           @source,
           path,
           index,
           chunk,
           file_hash,
           vector,
           package: nil,
           version: nil,
           model: model
         ) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
