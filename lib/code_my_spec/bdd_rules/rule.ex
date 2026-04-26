defmodule CodeMySpec.BddRules.Rule do
  @moduledoc """
  Ecto schema for a Rule (blue card) produced during a Three Amigos session.

  A Rule belongs to a Story and groups one or more scenarios (Criteria) that
  illustrate it. Rules are first-class persisted records — not strings on a
  Criterion — so the readiness gate ("every rule has happy + failure
  scenarios") can be enforced with joins, and ordering / addressability are
  explicit.

  Lives under the `BddRules` namespace to avoid colliding with the existing
  `CodeMySpec.Rules` module (which serves coding-convention markdown rules
  used by agent task prompts). In the Three Amigos / Example Mapping
  vocabulary the artifact is just "rule" — the `Bdd` prefix is a Module
  namespacing concern, not a domain term.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Accounts.Account
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Stories.Story

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          story_id: integer() | nil,
          statement: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "bdd_rules" do
    field :statement, :string

    belongs_to :account, Account, type: :binary_id
    belongs_to :project, Project, type: :binary_id
    belongs_to :story, Story

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [:account_id, :project_id, :story_id, :statement])
    |> validate_required([:account_id, :project_id, :story_id, :statement])
    |> validate_length(:statement, min: 1, max: 1000)
    |> assoc_constraint(:account)
    |> assoc_constraint(:project)
    |> assoc_constraint(:story)
  end
end
