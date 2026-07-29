defmodule CodeMySpec.Embeddings.PgVectorBackend do
  @moduledoc """
  Postgres/pgvector backend for the embedding pipeline, used by `:dev_sprite`.

  PARTIAL. `delete_path/3` works — it is plain Ecto and adapter-agnostic.
  `embed_file/4` and `search/3` are not ported: `EmbeddingService` generates
  vectors with Ortex and reads and writes them through sqlite_vec's SQL, so
  the storage and similarity halves need a pgvector equivalent rather than a
  delegation.

  They raise instead of returning a plausible empty result. A sprite that
  silently returned no matches for every semantic search would look like a
  project with nothing in it, and that failure is much harder to attribute
  than a crash naming this module.

  Everything else about a sprite works against Postgres today — this is the
  one place the schema reconciliation did not carry the code with it. The
  table and its HNSW index already exist (migration 20260729010000), so what
  remains is the service layer, not the data model.
  """

  @behaviour CodeMySpec.Embeddings.Backend

  import Ecto.Query

  alias CodeMySpec.Embeddings.DocEmbedding
  alias CodeMySpec.Repo

  @not_ported """
  Embedding generation and similarity search are not yet ported to pgvector.

  The doc_embeddings table and its HNSW index exist in Postgres; what is
  missing is a Postgres-flavoured EmbeddingService — Ortex for generation
  plus pgvector operators for search, in place of sqlite_vec's SQL.
  """

  @impl true
  def embed_file(_project_id, _source, _path, _content), do: raise(@not_ported)

  @impl true
  def search(_project_id, _query, _opts), do: raise(@not_ported)

  # Adapter-agnostic: no vector operations involved, so this one ports as-is.
  @impl true
  def delete_path(project_id, source, path) do
    {count, _} =
      from(e in DocEmbedding,
        where: e.project_id == ^project_id and e.source == ^source and e.path == ^path
      )
      |> Repo.delete_all()

    {:ok, count}
  end
end
