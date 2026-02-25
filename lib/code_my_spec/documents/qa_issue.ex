defmodule CodeMySpec.Documents.QaIssue do
  @moduledoc """
  Embedded schema representing a QA-discovered issue parsed from a result's ## Issues section.
  Contains title, severity, and description. Only medium+ severity issues get standalone files.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @derive Jason.Encoder
  @primary_key false

  @severities ~w(critical high medium low info)

  embedded_schema do
    field :title, :string
    field :severity, :string
    field :description, :string
  end

  def changeset(issue \\ %__MODULE__{}, attrs) do
    issue
    |> cast(attrs, [:title, :severity, :description])
    |> validate_required([:title, :severity])
    |> validate_inclusion(:severity, @severities)
  end

  def fileable?(%__MODULE__{severity: s}) when s in ~w(critical high medium), do: true
  def fileable?(_), do: false
end
