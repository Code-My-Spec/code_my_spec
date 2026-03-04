defmodule CodeMySpec.Documents.QaIssue do
  @moduledoc """
  Embedded schema representing a QA-discovered issue parsed from a result's ## Issues section.
  Contains title, severity, and description. All severity levels get standalone issue files.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false

  @severities ~w(critical high medium low info)
  @scopes ~w(app qa docs)

  embedded_schema do
    field :title, :string
    field :severity, :string
    field :description, :string
    field :scope, :string, default: "app"
  end

  def changeset(issue \\ %__MODULE__{}, attrs) do
    issue
    |> cast(attrs, [:title, :severity, :description, :scope])
    |> validate_required([:title, :severity])
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:scope, @scopes)
  end

  def fileable?(%__MODULE__{severity: s}) when s in @severities, do: true
  def fileable?(_), do: false
end
