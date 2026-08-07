defmodule CodeMySpec.ProjectSecrets.ProjectSecret do
  @moduledoc """
  A single piece of credential material belonging to a project.

  Holds the credentials that cannot be OAuth tokens — the Hetzner
  object-storage key pair (console-only, no API mints it) and the
  per-environment age private keys. OAuth-shaped provider connections
  live in `CodeMySpec.Integrations` as `Integration` rows instead.

  ## Security

  - `value` is encrypted at rest via `CodeMySpec.Encrypted.Binary`,
    following the precedent set by `projects.deploy_key`.
  - The value never leaves this context except through an explicit
    fetch. Listing returns keys only, so an agent enumerating a
    project's secrets sees names and never plaintext.

  ## Scoping

  Owned by exactly one of a project or an account, never both — the
  database enforces it with a check constraint.

  Project-scoped, not user-scoped, was the original choice: a user with
  two projects on different Hetzner accounts is representable, which
  `Integration`, keyed on `user_id`, cannot express.

  Account ownership was added because some credentials name something
  that outlives every project. A Hetzner API token is one Hetzner
  account, and the servers it can see are shared — keying it on the
  project made `/app/servers` show different boxes depending on which
  project happened to be open. Age keys stay project-scoped; they are
  genuinely per-project-per-environment.

  ## Environment

  `environment` is required and defaults to `"global"` rather than
  being nullable. A nullable discriminator would let two rows share a
  key with `NULL` environment under Postgres NULL semantics, since
  `NULL` never equals `NULL` in a unique index. Making it explicit
  keeps one unique index honest: age keys live under `"prod"` and
  `"uat"`, the S3 pair under `"global"`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          project_id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          key: String.t(),
          value: binary(),
          environment: String.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "project_secrets" do
    field :key, :string
    field :value, CodeMySpec.Encrypted.Binary
    field :environment, :string, default: "global"

    belongs_to :project, CodeMySpec.Projects.Project, type: :binary_id
    belongs_to :account, CodeMySpec.Accounts.Account, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a changeset for a secret belonging to `project_id`.

  The project is supplied by the repository from the caller's scope, never
  cast from user input — that is what keeps one project's secrets out of
  another's reach.
  """
  @spec changeset(t() | Ecto.Schema.t(), map(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def changeset(secret, attrs, project_id) do
    secret
    |> common(attrs)
    |> put_change(:project_id, project_id)
    |> put_change(:account_id, nil)
    |> unique_constraint([:project_id, :key, :environment],
      name: :project_secrets_project_id_key_environment_index
    )
  end

  @doc """
  Builds a changeset for a secret belonging to `account_id`.

  The mirror of `changeset/3` at the account grain. Both clear the other
  owner explicitly rather than leaving it untouched, so an update can move
  a secret between grains without tripping the check constraint.
  """
  @spec account_changeset(t() | Ecto.Schema.t(), map(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def account_changeset(secret, attrs, account_id) do
    secret
    |> common(attrs)
    |> put_change(:account_id, account_id)
    |> put_change(:project_id, nil)
    |> unique_constraint([:account_id, :key, :environment],
      name: :project_secrets_account_id_key_environment_index
    )
  end

  defp common(secret, attrs) do
    secret
    |> cast(attrs, [:key, :value, :environment])
    |> validate_required([:key, :value, :environment])
    |> validate_length(:key, min: 1, max: 255)
    |> check_constraint(:project_id,
      name: :project_secrets_exactly_one_owner,
      message: "a secret belongs to exactly one of a project or an account"
    )
  end
end
