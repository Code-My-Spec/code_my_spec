defmodule CodeMySpec.Sessions.Subagent do
  @moduledoc """
  Embedded schema for a registered sub-agent on a session.

  Carries the sub-agent's identity (`agent_id`, `agent_name`) and the most
  recent timestamp we have evidence-of-life — set at `SubagentStart` and
  refreshed on re-registration. PostToolUse does NOT refresh this (kept
  out of the tool-use handler's concerns).

  Registrations whose `last_heartbeat_at` is older than
  `ProjectConfiguration.subagent_ttl_minutes` are filtered out by
  `Session.active_subagents/2` on read — lazy prune, no DB mutation.

  Assignment is NOT tracked here. `Task.agent_id` is the source of truth
  for "this task is owned by that sub-agent."
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: String.t() | nil,
          agent_id: String.t() | nil,
          agent_name: String.t() | nil,
          last_heartbeat_at: DateTime.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :id, :string
    field :agent_id, :string
    field :agent_name, :string
    # Microsecond precision matches Task.started_at — keeps the session
    # schema at one resolution, and makes "registered very recently"
    # observable without a sleep on re-register paths.
    field :last_heartbeat_at, :utc_datetime_usec
  end

  @doc "Changeset for creating or updating a sub-agent registration."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(subagent \\ %__MODULE__{}, attrs) do
    subagent
    |> cast(attrs, [:id, :agent_id, :agent_name, :last_heartbeat_at])
    |> validate_required([:agent_id, :last_heartbeat_at])
    |> put_id_if_missing()
  end

  defp put_id_if_missing(changeset) do
    case fetch_field(changeset, :id) do
      {_source, nil} -> put_change(changeset, :id, Ecto.UUID.generate())
      :error -> put_change(changeset, :id, Ecto.UUID.generate())
      _ -> changeset
    end
  end
end
