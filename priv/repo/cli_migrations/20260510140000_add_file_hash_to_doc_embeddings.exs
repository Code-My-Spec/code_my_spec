defmodule CodeMySpec.Repo.Migrations.AddFileHashToDocEmbeddings do
  use Ecto.Migration

  # File-level SHA-256 lets `embed_file/4` short-circuit when the file's
  # bytes haven't changed since the last sync, avoiding the per-file
  # chunked-rescan + SELECT-existing-hashes + DELETE-stale on every boot
  # of `sync_framework_knowledge`.
  #
  # Existing rows get nil; the first re-embed populates them.

  def change do
    alter table(:doc_embeddings) do
      add :file_hash, :string
    end

    create index(:doc_embeddings, [:project_id, :source, :path, :file_hash])
  end
end
