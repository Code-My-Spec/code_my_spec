defmodule CodeMySpec.Embeddings.PgVectorBackend do
  @moduledoc """
  Postgres/pgvector backend for the embedding pipeline, used by `:dev_sprite`.

  `EmbeddingService` is almost entirely adapter-agnostic — chunking, content
  hashing, the file_hash fast path, stale-chunk deletion and file walking are
  all plain Ecto or plain Elixir. Exactly two statements were written against
  sqlite_vec, and only those are reimplemented here:

    * the chunk upsert, which used `vec_f32(?)` and `?N` placeholders
    * the similarity query, which used `vec_distance_cosine(...)`

  Everything else is delegated, so the two backends cannot drift on chunk
  sizes, hashing, or dedupe semantics.

  Vectors bind as `text` and are cast `::text::vector` in SQL rather than
  `::vector` directly. A bare `::vector` cast makes the PARAMETER type
  `vector`, which Postgrex cannot encode without the pgvector extension
  registered in a custom types module — casting from text keeps the parameter
  a plain string and avoids the dependency. The `::text::uuid` casts are the
  same trick for the same reason: a bare `::uuid` makes Postgrex demand a
  16-byte binary rather than the string form used everywhere else. `<=>` is pgvector's
  cosine-distance operator, matching the HNSW index built with
  `vector_cosine_ops`.
  """

  @behaviour CodeMySpec.Embeddings.Backend

  require Logger

  import Ecto.Query

  alias CodeMySpec.Embeddings.{DocEmbedding, EmbeddingService, Serving}
  alias CodeMySpec.Repo
  alias Ecto.Adapters.SQL, as: AdaptersSQL

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
    limit = Keyword.get(opts, :limit, 10)
    source = Keyword.get(opts, :source)
    source_prefix = Keyword.get(opts, :source_prefix)

    with {:ok, embedding} <- Serving.embed(query) do
      {where, params} = build_where(project_id, source, source_prefix)
      vector = encode_vector(embedding)
      n = length(params)

      sql = """
      SELECT e.source, e.path, e.chunk_index, e.content
      FROM doc_embeddings e
      #{where}
      ORDER BY e.embedding <=> $#{n + 1}::text::vector
      LIMIT $#{n + 2}
      """

      case AdaptersSQL.query(Repo, sql, params ++ [vector, limit]) do
        {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &row_to_result/1)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Store one chunk. Called by `EmbeddingService` in place of its sqlite_vec
  INSERT when this backend is active.

  `DO UPDATE`, not `DO NOTHING`: when a file changes, the row for this
  (project_id, source, path, chunk_index) already exists from the prior
  version. Doing nothing would drop the new chunk, and the stale-chunk
  cleanup that runs next would then delete the old row too — leaving the
  file with no embeddings at all.
  """
  def store_chunk(project_id, source, path, index, chunk, hash, file_hash) do
    with {:ok, embedding} <- Serving.embed(chunk) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # The conflict target must match whichever partial unique index applies,
      # so shared rows (project_id IS NULL) name their own.
      conflict =
        if is_nil(project_id) do
          "(source, path, chunk_index) WHERE project_id IS NULL"
        else
          "(project_id, source, path, chunk_index) WHERE project_id IS NOT NULL"
        end

      sql = """
      INSERT INTO doc_embeddings
        (id, project_id, source, path, chunk_index, content, content_hash, file_hash,
         embedding, inserted_at, updated_at)
      VALUES ($1::text::uuid, $2::text::uuid, $3, $4, $5, $6, $7, $8, $9::text::vector, $10, $11)
      ON CONFLICT #{conflict} DO UPDATE SET
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
        encode_vector(embedding),
        now,
        now
      ]

      case AdaptersSQL.query(Repo, sql, params) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # pgvector accepts its text form, "[1,2,3]" — the same shape Jason produces
  # for a list of floats.
  defp encode_vector(embedding), do: Jason.encode!(embedding)

  defp build_where(project_id, source, _prefix) when not is_nil(source),
    do: {"WHERE e.project_id = $1::text::uuid AND e.source = $2", [project_id, source]}

  defp build_where(project_id, _source, prefix) when not is_nil(prefix),
    do: {"WHERE e.project_id = $1::text::uuid AND e.source LIKE $2", [project_id, prefix <> "%"]}

  defp build_where(project_id, _source, _prefix),
    do: {"WHERE e.project_id = $1::text::uuid", [project_id]}

  defp row_to_result([src, path, chunk_index, content]),
    do: %{source: src, path: path, chunk_index: chunk_index, content: content}
end
