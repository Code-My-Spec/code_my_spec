defmodule CodeMySpec.Agents.Agent do
  @moduledoc """
  One coding agent CodeMySpec started, on one working copy, on one provider.

  `working_copy` is the root path the agent runs in, and it is the natural key
  for everything else about it — the harness serving that copy, the requirements
  it can see, the session its turns are attributed to. Every other harness
  surface is keyed the same way.

  `config_dir` is Pi's configuration directory for this agent
  (`PI_CODING_AGENT_DIR`), recorded rather than derived so a stop knows what to
  clean up even if the naming scheme changes underneath it. It is stored, and
  therefore assertable, because two rules depend on where it is: never inside
  the working copy, and never shared between tenants.

  `os_pid` is nullable on purpose. It is unknown between the row being written
  and the harness answering, and it stays null for an agent that failed to
  start — which is a different state from one that started and exited, and the
  two must not collapse into each other.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias CodeMySpec.Projects.Project

  @statuses [:starting, :running, :stopped, :failed]
  @engines [:pi, :claude_code]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          engine: atom() | nil,
          provider: String.t() | nil,
          working_copy: String.t() | nil,
          config_dir: String.t() | nil,
          os_pid: integer() | nil,
          status: atom() | nil,
          harness_id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t() | nil,
          project: Project.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agents" do
    field :engine, Ecto.Enum, values: @engines, default: :pi
    field :provider, :string
    field :working_copy, :string
    field :config_dir, :string
    field :os_pid, :integer
    field :status, Ecto.Enum, values: @statuses, default: :starting
    field :harness_id, Ecto.UUID
    field :account_id, Ecto.UUID

    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @spec engines() :: [atom()]
  def engines, do: @engines

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :engine,
      :provider,
      :working_copy,
      :config_dir,
      :os_pid,
      :status,
      :harness_id,
      :project_id,
      :account_id
    ])
    |> validate_required([:engine, :provider, :working_copy, :project_id, :account_id])
    |> validate_config_dir_outside_working_copy()
    |> assoc_constraint(:project)
  end

  # Rule 4, enforced where it cannot be forgotten. A working copy is a git
  # repository whose purpose is to be committed and pushed — `agent.sh` runs
  # `git add -A` on a clean exit — so a credential directory inside the tree is
  # a scheduled leak rather than a risk of one. Cheap to check here, and the
  # alternative is trusting every future caller to construct the path correctly.
  defp validate_config_dir_outside_working_copy(changeset) do
    config_dir = get_field(changeset, :config_dir)
    working_copy = get_field(changeset, :working_copy)

    validate_containment(changeset, config_dir, working_copy)
  end

  defp validate_containment(changeset, nil, _working_copy), do: changeset
  defp validate_containment(changeset, _config_dir, nil), do: changeset

  defp validate_containment(changeset, config_dir, working_copy) do
    contained? =
      config_dir
      |> Path.expand()
      |> String.starts_with?(Path.expand(working_copy) <> "/")

    reject_containment(changeset, contained?)
  end

  defp reject_containment(changeset, false), do: changeset

  defp reject_containment(changeset, true) do
    add_error(
      changeset,
      :config_dir,
      "must sit outside the working copy — it holds auth.json, and the copy gets committed"
    )
  end
end
