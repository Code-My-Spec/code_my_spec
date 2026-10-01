defmodule CodeMySpec.Repo.Migrations.EmbeddingsReworkStep1Schema do
  use Ecto.Migration

  # Embeddings rework step 1 (577de9bb). Existing doc_embeddings rows are
  # dead — nothing in production writes them today (the web build has no
  # backend configured, and the harness starts neither Serving nor
  # FileWatcherServer) — so there is nothing to migrate forward. Truncate
  # rather than carry rows nobody can account for into a schema that
  # changes what they mean.
  def up do
    execute("TRUNCATE TABLE doc_embeddings")

    alter table(:doc_embeddings) do
      add :package, :string
      add :version, :string
      add :model, :string
    end

    # A shared row's existing uniqueness (`doc_embeddings_shared_path_chunk_index`,
    # on source/path/chunk_index — 20260729020000) stays: it is the general
    # dedup/upsert target `store_embedded_chunk/8` already writes against, and
    # changing it is a write-path decision for whichever step actually starts
    # writing package/version, not a schema-only one.
    #
    # This index is additive: multiple versions of one package's docs can
    # coexist (two projects pinning different versions of the same
    # dependency), which `source` alone — "hexdocs:<pkg>", no version — can't
    # tell apart.
    create unique_index(:doc_embeddings, [:package, :version, :model, :path, :chunk_index],
             where: "project_id IS NULL",
             name: :doc_embeddings_shared_identity_index
           )

    create index(:doc_embeddings, [:package, :version])

    # The completeness marker. A package@version with zero rows (no docs at
    # all — most hex packages) and one that died halfway through embedding
    # both look identical from doc_embeddings alone; this is the thing that
    # says "done", written last, in the same transaction as the final chunk.
    create table(:doc_packages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :package, :string, null: false
      add :version, :string, null: false
      add :model, :string, null: false
      add :status, :string, null: false
      add :chunk_count, :integer
      add :error, :text
      add :embedded_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:doc_packages, [:package, :version, :model])

    # The reconciler's checksum, verified against the hex.pm tarball before
    # anything is parsed. Lockfile.entry/1 already parses the hex tuple's
    # outer checksum; it was discarded on the way into project_dependencies
    # because nothing read it yet.
    alter table(:project_dependencies) do
      add :checksum, :string
    end
  end

  def down do
    alter table(:project_dependencies) do
      remove :checksum
    end

    drop table(:doc_packages)

    drop index(:doc_embeddings, [:package, :version])

    drop index(:doc_embeddings, [:package, :version, :model, :path, :chunk_index],
           name: :doc_embeddings_shared_identity_index
         )

    alter table(:doc_embeddings) do
      remove :package
      remove :version
      remove :model
    end
  end
end
