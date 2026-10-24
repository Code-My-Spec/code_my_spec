defmodule CodeMySpec.Embeddings.DocPackage do
  @moduledoc """
  Whether `package@version`'s docs are fully embedded, for one model.

  `doc_embeddings` alone can't answer this: a job that died halfway leaves
  some chunks behind and looks present, and a package with no docs (most of
  them) has zero rows and looks missing forever. This row is written last,
  in the same transaction as the final chunk, so "present" means "complete".
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(pending embedded no_docs failed)

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "doc_packages" do
    field :package, :string
    field :version, :string
    field :model, :string
    field :status, :string
    field :chunk_count, :integer
    field :error, :string
    field :embedded_at, :utc_datetime_usec
    field :attempts, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(doc_package, attrs) do
    doc_package
    |> cast(attrs, [
      :package,
      :version,
      :model,
      :status,
      :chunk_count,
      :error,
      :embedded_at,
      :attempts
    ])
    |> validate_required([:package, :version, :model, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:package, :version, :model])
  end
end
