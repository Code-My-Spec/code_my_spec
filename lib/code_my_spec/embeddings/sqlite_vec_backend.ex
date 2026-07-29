defmodule CodeMySpec.Embeddings.SqliteVecBackend do
  @moduledoc """
  Sqlite_vec + Ortex backend for the embedding pipeline.

  This is the production backend used by the CodeMySpec CLI binary.
  It delegates storage and search to `EmbeddingService` (which talks
  to the SQLite-backed `doc_embeddings` table) and embedding
  generation to the configured `Embeddings.Serving` (Ortex).

  Not used in `:test` — the test env doesn't have sqlite_vec or Ortex.
  See `CodeMySpec.Embeddings.TestBackend`.
  """

  @behaviour CodeMySpec.Embeddings.Backend

  import Ecto.Query

  alias CodeMySpec.Embeddings.{DocEmbedding, EmbeddingService, Serving}
  alias Ecto.Adapters.SQL, as: AdaptersSQL
  alias CodeMySpec.Repo

  @impl true
  def embed_file(project_id, source, path, content) do
    EmbeddingService.embed_file(project_id, source, path, content)
  end

  @impl true
  def delete_path(project_id, source, path) do
    {count, _} =
      from(e in DocEmbedding,
        where: e.project_id == ^project_id and e.source == ^source and e.path == ^path
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  @impl true
  def search(project_id, query, opts) do
    EmbeddingService.search(project_id, query, opts)
  end

  @doc """
  Persist one embedded chunk via sqlite_vec.

  Moved here from `EmbeddingService` when `store_chunk/7` became a Backend
  callback — it is the one step whose SQL cannot be shared with pgvector
  (`vec_f32()`, `?N` placeholders).

  `DO UPDATE`, not `DO NOTHING`: when a file is modified the row for this
  (project_id, source, path, chunk_index) already exists from the prior
  version. Doing nothing would drop the new chunk, and the `delete_old_chunks`
  pass that runs next would then remove the old row too — leaving the file
  with zero embeddings. (Issue b3826070, story 688 R5970.)
  """
  @impl true
  def store_chunk(project_id, source, path, index, chunk, hash, file_hash) do
    with {:ok, embedding} <- Serving.embed(chunk) do
      vector_json = Jason.encode!(embedding)
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      sql = """
      INSERT INTO doc_embeddings (id, project_id, source, path, chunk_index, content, content_hash, file_hash, embedding, inserted_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, vec_f32(?9), ?10, ?11)
      ON CONFLICT (project_id, source, path, chunk_index) DO UPDATE SET
        content = excluded.content,
        content_hash = excluded.content_hash,
        file_hash = excluded.file_hash,
        embedding = excluded.embedding,
        updated_at = excluded.updated_at
      """

      params = [
        UUID.uuid4(),
        project_id,
        source,
        path,
        index,
        chunk,
        hash,
        file_hash,
        vector_json,
        now,
        now
      ]

      case AdaptersSQL.query(Repo, sql, params) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
