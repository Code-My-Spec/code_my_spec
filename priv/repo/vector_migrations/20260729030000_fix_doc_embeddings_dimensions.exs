defmodule CodeMySpec.Repo.Migrations.FixDocEmbeddingsDimensions do
  use Ecto.Migration

  # The SQLite schema declares `float[1024]`, so 20260729010000 ported 1024.
  # The serving actually produces 384-dimension vectors (all-MiniLM-L6-v2 —
  # `EmbeddingService`'s own moduledoc says so).
  #
  # sqlite_vec never enforced the declared width, so the mismatch sat there
  # harmlessly. pgvector checks on insert:
  #
  #   ERROR 22000 expected 1024 dimensions, not 384
  #
  # 384 is the real contract. Worth noting that centralizing surfaced a latent
  # inconsistency the previous storage engine was silently tolerating — if the
  # model is ever swapped for a wider one, this column and the index have to
  # move with it, which is now enforced rather than assumed.
  #
  # The HNSW index is dropped and rebuilt because it is bound to the column
  # type. Safe to do in one migration while the table is empty; against a
  # populated table this wants a concurrent rebuild instead.
  def up do
    execute("DROP INDEX IF EXISTS doc_embeddings_embedding_index")
    execute("ALTER TABLE doc_embeddings ALTER COLUMN embedding TYPE vector(384)")

    execute(
      "CREATE INDEX doc_embeddings_embedding_index ON doc_embeddings " <>
        "USING hnsw (embedding vector_cosine_ops)"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS doc_embeddings_embedding_index")
    execute("ALTER TABLE doc_embeddings ALTER COLUMN embedding TYPE vector(1024)")

    execute(
      "CREATE INDEX doc_embeddings_embedding_index ON doc_embeddings " <>
        "USING hnsw (embedding vector_cosine_ops)"
    )
  end
end
