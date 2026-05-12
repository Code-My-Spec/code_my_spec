defmodule CodeMySpec.Embeddings.DocEmbedding do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  @embedding_type if Code.ensure_loaded?(SqliteVec.Ecto.Float32),
                    do: SqliteVec.Ecto.Float32,
                    else: :binary

  schema "doc_embeddings" do
    field :project_id, :string
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
