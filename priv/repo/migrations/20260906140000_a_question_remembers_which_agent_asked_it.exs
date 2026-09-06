defmodule CodeMySpec.Repo.Migrations.AQuestionRemembersWhichAgentAskedIt do
  @moduledoc """
  Who to hand the answer back to.

  A question already carries `session_external_id`, which is how it finds the
  conversation it should appear in. That is enough to *show* an answer and not
  enough to *deliver* one: an agent we run has an id of its own, and the session
  resolved from its working copy is not it.

  So an agent that asked had no way to be told. `check_answer` covered the gap
  by polling, which works only for an agent that keeps running — and an agent
  waiting on a person should be stopped, not burning a turn per check on
  somebody who has not started typing.

  Nullable, and the null means something rather than being a gap: a question
  asked by a Claude Code session has no agent, and that path still polls.
  `nilify_all` because a deleted agent must not take the record of what was
  asked with it — the question and its answer are the person's, and they outlive
  whichever process happened to ask.
  """

  use Ecto.Migration

  def change do
    alter table(:question_requests) do
      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
    end

    # Answering looks up by question id; this index is for the other direction —
    # "is this agent waiting on anything", asked on every stop decision.
    create index(:question_requests, [:agent_id, :status])
  end
end
