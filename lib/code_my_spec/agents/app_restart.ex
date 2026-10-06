defmodule CodeMySpec.Agents.AppRestart do
  @moduledoc """
  One restart of a working copy's whole app, as opposed to one agent.

  `RestartApp` acts on a working copy, not an agent (it has no agent to
  name), so this is not `agent_restarts`. Whether it served a story is not
  stamped here -- it is read from `agents.story_id` against this row's
  `working_copy_id` at report time, the same choice `Interventions` already
  makes for agent-level restarts.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          working_copy_id: Ecto.UUID.t() | nil,
          project_id: Ecto.UUID.t() | nil,
          reason: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "app_restarts" do
    field :working_copy_id, Ecto.UUID
    field :project_id, Ecto.UUID
    field :reason, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(app_restart, attrs) do
    app_restart
    |> cast(attrs, [:working_copy_id, :project_id, :reason])
    |> validate_required([:working_copy_id, :project_id, :reason])
  end
end
