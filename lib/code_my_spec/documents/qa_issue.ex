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

  # Read off `Issue`, not restated. A QA result reports issues into the same
  # domain the schema defines, so a scope one accepts and the other does not is
  # a finding with nowhere to go.
  #
  # It was restated, and drifted: `9198be0f` added `:framework` to `Issue`,
  # `Issues`, `create_issue` and `list_issues` and missed this list and
  # `Documents.@valid_scopes`, three months ago. `Issues.parse_scope/1` grew a
  # `"framework"` clause that this rejected before it could ever run — so the
  # code that files the issue expected it to work and the code that validates
  # the document it arrives in did not.
  #
  # A QA agent hits framework friction more than anyone: the harness itself, a
  # looping hook, a tool that will not answer. Rejecting the document is
  # rejecting the only channel that has.
  @scopes CodeMySpec.Issues.Issue |> Ecto.Enum.values(:scope) |> Enum.map(&Atom.to_string/1)

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
