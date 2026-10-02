defmodule CodeMySpec.Repo.Migrations.DropLegacySharedPathChunkIndex do
  @moduledoc """
  577de9bb step 3's first real sweep hit this within minutes: the old
  shared-row uniqueness, `(source, path, chunk_index) WHERE project_id IS
  NULL`, has no version column, so two different versions of the same hex
  package — ordinary once more than one project locks a package, each at
  its own version — collide on the identical `hexdocs:<pkg>` + path +
  chunk 0. Eight packages failed this way in the first sweep (credo,
  decimal, db_connection, deep_merge, boundary, anubis_mcp, client_utils,
  code_my_spec_generators).

  `doc_embeddings_shared_identity_index` (package, version, model, path,
  chunk_index), added in step 1, is what every shared write actually
  targets now — this one is redundant and actively wrong. Every
  `project_id IS NULL` row in production already carries package/version/
  model, confirmed directly before writing this.

  No `default:`, nothing destructive — an index drop only.
  """

  use Ecto.Migration

  def up do
    drop index(:doc_embeddings, [:source, :path, :chunk_index],
           where: "project_id IS NULL",
           name: :doc_embeddings_shared_path_chunk_index
         )
  end

  def down do
    create unique_index(:doc_embeddings, [:source, :path, :chunk_index],
             where: "project_id IS NULL",
             name: :doc_embeddings_shared_path_chunk_index
           )
  end
end
