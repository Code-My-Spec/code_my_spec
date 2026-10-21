defmodule CodeMySpec.Embeddings.DocEmbedding do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  # SQLite stored project_id as TEXT; Postgres uses a real uuid column with a
  # foreign key to projects. Declaring
  # :string against a uuid column fails at the driver with "expected a binary
  # of 16 bytes".
  @project_id_type (case Application.compile_env(:code_my_spec, :adapter) do
                      Ecto.Adapters.SQLite3 -> :string
                      _ -> :binary_id
                    end)

  schema "doc_embeddings" do
    field :project_id, @project_id_type
    field :source, :string
    field :path, :string
    field :chunk_index, :integer, default: 0
    field :content, :string
    field :content_hash, :string
    field :file_hash, :string
    # Raw SQL reads and writes it (see Embeddings.PgVectorBackend).
    field :embedding, :binary

    # Set for shared rows (hex docs, framework knowledge); NULL for a
    # project's own content. `model` keeps a serving swap from silently
    # mixing vector spaces — a change becomes a re-embed, not a bad answer.
    field :package, :string
    field :version, :string
    field :model, :string

    timestamps(type: :utc_datetime_usec)
  end
end
