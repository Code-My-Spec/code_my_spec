defmodule CodeMySpec.Repo.Migrations.AQuestionSaysWhoIsHoldingIt do
  @moduledoc """
  A question waits on somebody, and until now the row could not say who.

  Story 1053. `status` has two values and answers a different question —
  finished or not — so an unanswered question that the main agent has already
  looked at and passed up is indistinguishable from one nobody has read. Both
  are `pending`, and both readers want the opposite thing from that word: the
  main agent wants the ones still needing it, the person wants the ones that
  reached them.

  Deleting the row on escalation and marking it answered were the two obvious
  alternatives and are the two failures criterion 3264 names. Gone, the main
  agent cannot tell an escalation it dealt with from one it did not, and the
  asking agent has nobody tracking its question. Answered, the person's question
  disappears from under them while they are looking at it. So a question needs a
  holder rather than a boolean.

  `user` is the backfill for every existing row, and it is right rather than
  convenient: every question written before this reached the user's inbox and
  waits on them. Nothing had passed through a main agent, because there was no
  main agent to pass through.

  No column default — the schema carries it, so the code that writes rows is
  what decides, and a row inserted without one fails loudly here instead of
  quietly acquiring a holder nobody chose.
  """

  use Ecto.Migration

  def change do
    alter table(:question_requests) do
      add :holder, :string
      add :escalation_reason, :text
    end

    execute "UPDATE question_requests SET holder = 'user'", ""

    # The main agent's listing reads exactly this pair — the questions on its
    # project still held by it — and reads it on every check-in.
    create index(:question_requests, [:holder, :status])
  end
end
