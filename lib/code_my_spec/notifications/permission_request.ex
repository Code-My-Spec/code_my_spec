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
    field :tool_input, :map
    field :status, :string, default: "pending"
    field :decision, :string

    belongs_to :user, CodeMySpec.Users.User, type: :id

    timestamps(type: :utc_datetime)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:user_id, :tool_name, :tool_input, :status, :decision])
    |> validate_required([:user_id, :tool_name, :tool_input])
    |> validate_inclusion(:status, ~w(pending approved denied expired))
    |> validate_inclusion(:decision, ~w(allow deny ask), message: "must be allow, deny, or ask")
  end
end
