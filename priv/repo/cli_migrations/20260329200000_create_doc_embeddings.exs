defmodule CodeMySpec.Repo.Migrations.CreateDocEmbeddings do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE doc_embeddings (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES projects(id),
      source TEXT NOT NULL,
      path TEXT NOT NULL,
      chunk_index INTEGER NOT NULL DEFAULT 0,
      content TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      embedding float[1024],
      inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    )
    """)

    execute("CREATE INDEX doc_embeddings_project_id_index ON doc_embeddings(project_id)")
    execute("CREATE INDEX doc_embeddings_source_path_index ON doc_embeddings(source, path)")
    execute("CREATE UNIQUE INDEX doc_embeddings_content_hash_index ON doc_embeddings(project_id, content_hash)")
  end

  def down do
    execute("DROP TABLE doc_embeddings")
  end
end
