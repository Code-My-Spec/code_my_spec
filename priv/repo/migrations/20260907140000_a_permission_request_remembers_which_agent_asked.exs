defmodule CodeMySpec.Repo.Migrations.APermissionRequestRemembersWhichAgentAsked do
  @moduledoc """
  Who to tell when the human decides.

  `tap_out` is built on a Claude Code session: it writes the pending request
  into `session.state` and a waiter polls it. An agent we run has no session to
  write into, so the tool refused it outright — which meant the one escape the
  stop menu offers on every refusal inside the loop was offered to agents that
  could not take it.

  The session state was never the interesting part. The permission request row
  *is* the pending state; `session.state` was a second copy of it for a waiter
  that an agent does not need. What an agent needs is the answer delivered back
  — approved and the loop is done, denied and it keeps going — which is the same
  push `question_requests.agent_id` carries for a question.

  Nullable, and the null is ordinary: a permission request from Claude Code has
  no agent and is answered through the SSE connection that is already waiting on
  it. `nilify_all` because the decision is the person's and outlives whichever
  process asked.
  """

  use Ecto.Migration

  def change do
    alter table(:permission_requests) do
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:permission_requests, [:agent_id, :status])
  end
end
