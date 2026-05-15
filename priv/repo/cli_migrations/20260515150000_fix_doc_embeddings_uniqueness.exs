defmodule CodeMySpec.Repo.Migrations.FixDocEmbeddingsUniqueness do
  use Ecto.Migration

  # The original `(project_id, content_hash)` unique index was meant to
  # dedupe identical chunk content across the project. Combined with
  # `INSERT ... ON CONFLICT DO NOTHING` in
  # `EmbeddingService.generate_and_store/7`, it silently swallows the
  # insert when the same chunk content appears in two paths — leaving
  # the second path with zero rows. `EmbeddingService.embed_file/4`
  # then loops on that path every boot because `file_hash_matches?`
  # finds nothing to match against.
  #
  # Replace it with `(project_id, source, path, chunk_index)` so each
  # file's chunks get their own rows. Same-content chunks now live in
  # multiple rows; the per-file `file_hash` fast path still skips
  # re-embedding work when the file is unchanged.
  #
  # Also drop the orphaned `.code_my_spec/framework/...` rows from
  # `source=knowledge` — these came from an older version of the
  # framework_knowledge sync that walked the working tree, and they're
  # the rows whose existence caused the new boot-pass inserts to
  # collide on the old content_hash uniqueness.

  # The original index was created without an explicit name in
  # `20260329200000_create_doc_embeddings.exs`, but that migration used
  # `name: :doc_embeddings_content_hash_index` directly, so Ecto's
  # default naming (`doc_embeddings_project_id_content_hash_index`)
  # does NOT match what's on disk. Pass the explicit name when
  # dropping.

  def up do
    drop index(:doc_embeddings, [:project_id, :content_hash],
           name: :doc_embeddings_content_hash_index
         )

    create unique_index(:doc_embeddings, [:project_id, :source, :path, :chunk_index],
             name: :doc_embeddings_path_chunk_index
           )

    execute(
      "DELETE FROM doc_embeddings WHERE source = 'knowledge' AND path LIKE '.code_my_spec/framework/%'"
    )
  end

  def down do
    drop index(:doc_embeddings, [:project_id, :source, :path, :chunk_index],
           name: :doc_embeddings_path_chunk_index
         )

    create unique_index(:doc_embeddings, [:project_id, :content_hash],
             name: :doc_embeddings_content_hash_index
           )
  end
end
