defmodule CodeMySpec.Notifications.PermissionRequest do
  @moduledoc """
  Schema for remote permission approval requests from Claude Code.

  When Claude Code needs permission to run a tool, the local hook posts
  a request here and waits via SSE. The user approves/denies from their
  phone (via Web Push notification link) and the decision is broadcast
  back to the waiting hook.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "permission_requests" do
    field :tool_name, :string
    field :task_id, :string
    field :tool_input, :map
    field :status, :string, default: "pending"
    field :decision, :string

    # Set only by an escalation: the main agent's own reason it could not
    # decide this, and the person-facing framing of what approving or
    # denying actually changes. Nil means nobody has sent this up — the
    # computed holder reads that as "still main's, once aged" rather than
    # "already the user's".
    field :escalation_reason, :string
    field :escalated_as, :string

    # Which agent asked, so the decision can be delivered back to it. Nil for
    # a Claude Code request, which is answered on the SSE connection already
    # waiting on it.
    belongs_to :agent, CodeMySpec.Agents.Agent, type: :binary_id

    # The Claude Code session a tap-out's decision applies to. Nil otherwise.
    belongs_to :session, CodeMySpec.Sessions.Session, type: :binary_id

    belongs_to :user, CodeMySpec.Users.User, type: :id

    timestamps(type: :utc_datetime)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :user_id,
      :agent_id,
      :session_id,
      :task_id,
      :tool_name,
      :tool_input,
      :status,
      :decision,
      :escalation_reason,
      :escalated_as
    ])
    |> validate_required([:user_id, :tool_name, :tool_input])
    |> validate_inclusion(:status, ~w(pending approved denied expired))
    |> validate_inclusion(:decision, ~w(allow deny ask), message: "must be allow, deny, or ask")
  end
end
