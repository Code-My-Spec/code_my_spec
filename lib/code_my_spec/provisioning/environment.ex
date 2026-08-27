defmodule CodeMySpec.Provisioning.Environment do
  @moduledoc """
  One deployment target: a named remote server with connection metadata.

  `prod` and `uat` are rows, not concepts. A project can have a `qa`
  environment, or one per story, without a code change — which is the point.
  Steps fan out over whatever environments a project has and never test a name.

  Not to be confused with `CodeMySpec.Environments`, which is the execution
  abstraction (local / memory / container / cli) for *running commands*. This
  is a place to deploy to.

  ## Fields

  - `name` — `"prod"`, `"uat"`, `"qa-963"`. Becomes the server name, the DNS
    label and the SOPS key filename, so it is constrained to what all three
    accept.
  - `host` — the public hostname it answers on, stored rather than derived so
    no step has to special-case a name: production's is the apex, UAT's is
    `uat.<domain>`, and the DNS step simply points each host at its own IP.
  - `server_name` / `ip` — filled in by the server step. Null means "not
    provisioned yet", which is a real state: the environment is the plan and
    the server is the fulfilment.
  - `server_id` — an account-level `CodeMySpec.Servers.Server` this
    environment is served by, when it's a box the account already owns
    rather than one the server step created for it. Null is the common case.
    Story 879 deferred this exact re-grain: a box cannot be shared between
    projects, or adopted, while `server_name`/`ip` are the only record of it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          name: String.t(),
          host: String.t() | nil,
          server_name: String.t() | nil,
          ip: String.t() | nil,
          server_id: Ecto.UUID.t() | nil
        }

  schema "provisioning_environments" do
    field :name, :string
    field :host, :string
    field :server_name, :string
    field :ip, :string

    belongs_to :project, CodeMySpec.Projects.Project
    belongs_to :server, CodeMySpec.Servers.Server

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(environment, attrs) do
    environment
    |> cast(attrs, [:name, :host, :server_name, :ip, :project_id, :server_id])
    |> validate_required([:name, :project_id])
    # The same constraint the server name, the DNS label and the sops filename
    # each impose separately. Validating it once here means a bad name is
    # refused where it is created rather than three steps later, as a provider
    # rejecting something that reads like our bug.
    |> validate_format(:name, ~r/^[a-z][a-z0-9-]{0,30}$/,
      message: "must be lowercase letters, digits and dashes, starting with a letter"
    )
    |> unique_constraint([:project_id, :name])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:server_id)
  end
end
