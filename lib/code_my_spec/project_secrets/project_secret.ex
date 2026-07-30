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

  Project-scoped, not user-scoped. A user with two projects on
  different Hetzner accounts is representable — which `Integration`,
  keyed on `user_id`, cannot express.

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
          project_id: Ecto.UUID.t(),
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
    |> cast(attrs, [:key, :value, :environment])
    |> put_change(:project_id, project_id)
    |> validate_required([:key, :value, :environment])
    |> validate_length(:key, min: 1, max: 255)
    |> unique_constraint([:project_id, :key, :environment],
      name: :project_secrets_project_id_key_environment_index
    )
  end
end
