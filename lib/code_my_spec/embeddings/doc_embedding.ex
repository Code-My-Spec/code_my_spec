defmodule CodeMySpec.Embeddings.DocEmbedding do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  # Keyed on the configured adapter, not on whether a module happens to be
  # loaded. Module presence was a fine proxy while SQLite was the only place
  # this table lived; with :dev_sprite pointing the same schema at Postgres it
  # would silently pick the sqlite_vec type for a pgvector column — a wrong
  # type chosen by accident of the dependency tree rather than by the database
  # actually in use.
  #
  # Postgres resolves to :binary for now because the pgvector backend does not
  # read or write this field yet (see Embeddings.PgVectorBackend). When it
  # does, this becomes the pgvector Ecto type.
  @embedding_type (case Application.compile_env(:code_my_spec, :adapter) do
                     Ecto.Adapters.SQLite3 ->
                       if Code.ensure_loaded?(SqliteVec.Ecto.Float32),
                         do: SqliteVec.Ecto.Float32,
                         else: :binary

                     _ ->
                       :binary
                   end)

  # SQLite stored project_id as TEXT; Postgres uses a real uuid column with a
  # foreign key to projects. Same adapter split as @embedding_type — declaring
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
    field :embedding, @embedding_type

    timestamps(type: :utc_datetime)
  end
end
