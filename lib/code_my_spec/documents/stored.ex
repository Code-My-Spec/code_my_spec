defmodule CodeMySpec.Documents.Stored do
  @moduledoc "A project-owned markdown document persisted independently of working copies."

  use Ecto.Schema
  import Ecto.Changeset

  schema "documents" do
    field :document_type, :string
    field :story_number, :integer, default: 0
    field :content, :string
    field :project_id, Ecto.UUID
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [:project_id, :document_type, :story_number, :content])
    |> validate_required([:project_id, :document_type, :story_number, :content])
    |> unique_constraint([:project_id, :document_type, :story_number])
  end
end
