defmodule CodeMySpec.Repo.Migrations.FixDocEmbeddingsUniqueness do
  use Ecto.Migration

  # Corrects 20260729010000, which ported the ORIGINAL SQLite design rather
  # than the current one. The CLI replaced content-hash uniqueness in
  # 20260515150000 because it was actively broken:
  #
  #   `(project_id, content_hash)` unique + `INSERT ... ON CONFLICT` means
  #   the same chunk text appearing in two different paths silently swallows
  #   the second insert. That path ends up with zero rows, and because
  #   `embed_file/4`'s fast path has no row whose file_hash it can match, it
  #   re-embeds that file on every single boot, forever.
  #
  # Uniqueness belongs on the chunk's identity — (project_id, source, path,
  # chunk_index) — not on its content. content_hash stays as a change
  # detector, which is all it was ever good for.
  #
  # The NULL-project (shared) rows need their own partial index for the same
  # reason as before: Postgres treats NULLs as distinct, so they would fall
  # out of a composite index that includes project_id.
  def up do
    drop index(:doc_embeddings, [:project_id, :content_hash],
           name: :doc_embeddings_project_content_hash_index
         )

    drop index(:doc_embeddings, [:content_hash],
           name: :doc_embeddings_shared_content_hash_index
         )

    create unique_index(:doc_embeddings, [:project_id, :source, :path, :chunk_index],
             where: "project_id IS NOT NULL",
             name: :doc_embeddings_path_chunk_index
           )

    create unique_index(:doc_embeddings, [:source, :path, :chunk_index],
             where: "project_id IS NULL",
             name: :doc_embeddings_shared_path_chunk_index
           )

    # content_hash is still queried per file, just not unique.
    create index(:doc_embeddings, [:project_id, :source, :path, :content_hash],
             name: :doc_embeddings_content_hash_lookup_index
           )
  end

  def down do
    drop index(:doc_embeddings, [:project_id, :source, :path, :chunk_index],
           name: :doc_embeddings_path_chunk_index
         )

    drop index(:doc_embeddings, [:source, :path, :chunk_index],
           name: :doc_embeddings_shared_path_chunk_index
         )

    drop index(:doc_embeddings, [:project_id, :source, :path, :content_hash],
           name: :doc_embeddings_content_hash_lookup_index
         )

    create unique_index(:doc_embeddings, [:project_id, :content_hash],
             where: "project_id IS NOT NULL",
             name: :doc_embeddings_project_content_hash_index
           )

    create unique_index(:doc_embeddings, [:content_hash],
             where: "project_id IS NULL",
             name: :doc_embeddings_shared_content_hash_index
           )
  end
end
