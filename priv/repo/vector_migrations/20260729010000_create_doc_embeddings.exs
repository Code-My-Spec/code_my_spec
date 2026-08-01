defmodule CodeMySpec.Repo.Migrations.CreateDocEmbeddings do
  use Ecto.Migration

  # The last table that existed only in the CLI's SQLite schema. Every other
  # table the harness uses already exists here, so this is the whole gap
  # between "the harness runs on its own database" and "the harness runs on
  # the central one".
  #
  # Two differences from the SQLite original, both deliberate:
  #
  #   * `embedding` is a pgvector `vector(1024)` rather than sqlite_vec's
  #     `float[1024]`, so similarity search is an index scan instead of a
  #     sequential one.
  #
  #   * `project_id` is NULLABLE, meaning "shared across every project".
  #     Hex doc embeddings are derived from public packages and are byte
  #     identical for everyone on a given version — today every install
  #     recomputes and stores its own copy. Centralized, they are computed
  #     once. A project's own code keeps a non-null project_id.
  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector", "DROP EXTENSION IF EXISTS vector")

    create table(:doc_embeddings, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
      add :source, :string, null: false
      add :path, :string, null: false
      add :chunk_index, :integer, null: false, default: 0
      add :content, :text, null: false
      add :content_hash, :string, null: false
      add :file_hash, :string

      timestamps(type: :utc_datetime)
    end

    execute(
      "ALTER TABLE doc_embeddings ADD COLUMN embedding vector(1024)",
      "ALTER TABLE doc_embeddings DROP COLUMN embedding"
    )

    create index(:doc_embeddings, [:project_id])
    create index(:doc_embeddings, [:source, :path])

    # Postgres treats NULLs as distinct in a unique index, so a single index on
    # (project_id, content_hash) would enforce nothing for shared rows — every
    # insert would look unique and the dedupe this table exists for would
    # silently not happen. Two partial indexes instead, one per case.
    create unique_index(:doc_embeddings, [:project_id, :content_hash],
             where: "project_id IS NOT NULL",
             name: :doc_embeddings_project_content_hash_index
           )

    create unique_index(:doc_embeddings, [:content_hash],
             where: "project_id IS NULL",
             name: :doc_embeddings_shared_content_hash_index
           )

    # HNSW over cosine distance. Built after the column exists; on an empty
    # table this is instant, which is why it belongs in the same migration
    # rather than a later one against a populated table.
    execute(
      "CREATE INDEX doc_embeddings_embedding_index ON doc_embeddings " <>
        "USING hnsw (embedding vector_cosine_ops)",
      "DROP INDEX IF EXISTS doc_embeddings_embedding_index"
    )
  end

  def down do
    drop table(:doc_embeddings)
    execute("DROP EXTENSION IF EXISTS vector")
  end
end
