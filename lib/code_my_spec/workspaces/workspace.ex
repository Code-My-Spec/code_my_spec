defmodule CodeMySpec.Workspaces.Workspace do
  @moduledoc "Schema for a project's running instance."

  use Ecto.Schema
  import Ecto.Changeset

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Workspaces.BootSteps

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type status :: :booting | :running | :failed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          status: status(),
          step: BootSteps.step() | nil,
          container_name: String.t() | nil,
          port: pos_integer() | nil,
          error: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "workspaces" do
    field :status, Ecto.Enum, values: [:booting, :running, :failed]

    field :step, Ecto.Enum,
      values: [
        :starting_database,
        :generating,
        :reusing,
        :fetching_deps,
        :migrating,
        :starting_harness,
        :starting_app
      ]

    field :container_name, :string
    field :port, :integer
    field :error, :string
    field :booted_at, :utc_datetime

    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  @doc "A workspace the runner has accepted and which is now coming up."
  def booting_changeset(%__MODULE__{} = workspace, attrs) do
    workspace
    |> cast(attrs, [:project_id, :container_name, :port])
    |> validate_required([:project_id, :container_name, :port])
    |> put_change(:status, :booting)
    |> put_change(:error, nil)
    |> put_change(:step, nil)
    |> put_change(:booted_at, DateTime.utc_now(:second))
    |> unique_constraint(:project_id)
  end

  @doc "The phase the container last announced."
  def step_changeset(%__MODULE__{} = workspace, step) do
    change(workspace, step: step)
  end

  @doc "It came up."
  def running_changeset(%__MODULE__{} = workspace) do
    change(workspace, status: :running, error: nil)
  end

  @doc "It did not come up, and this is what the visitor gets told."
  def failed_changeset(%__MODULE__{} = workspace, error) when is_binary(error) do
    change(workspace, status: :failed, error: error)
  end

  @doc "Where to look at it. Only a running workspace has somewhere to point."
  @spec url(t()) :: String.t() | nil
  def url(%__MODULE__{status: :running, port: port}) when is_integer(port),
    do: "http://localhost:#{port}"

  def url(%__MODULE__{}), do: nil
end
