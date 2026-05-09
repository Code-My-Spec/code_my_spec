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

  alias CodeMySpec.Embeddings.{DocEmbedding, EmbeddingService}
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
end
