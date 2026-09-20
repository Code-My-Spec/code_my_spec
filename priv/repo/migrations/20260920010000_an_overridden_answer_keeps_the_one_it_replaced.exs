defmodule CodeMySpec.Repo.Migrations.AnOverriddenAnswerKeepsTheOneItReplaced do
  @moduledoc """
  An override erased what it overrode.

  Story 1052, criterion 3220. `overruled` says an earlier answer existed;
  nothing said what it was. The user opens a question the main agent answered,
  disagrees, and submits — and the reading they disagreed with is gone from the
  only page that ever showed it. The criterion's words are "retains the earlier
  answer for audit", and the point is not bookkeeping: a main agent that reads
  the records wrongly is a bug in how it reads them, and the evidence is the
  answer it gave.

  `answer_history` is an array rather than one prior answer, because the shape
  of "who answered before" is a list the moment anything overrides twice, and a
  single column would have to be widened by another migration the first time
  that happened.

  No column default. The schema carries `[]`, so a row inserted without one
  fails here rather than quietly acquiring a history nobody wrote — the same
  reasoning as `20260915120000_a_user_can_overrule_a_main_agents_answer`, which
  added the flag this column completes. Existing rows are backfilled to an
  empty history, which is true of all of them: nothing could be overridden
  before `overruled` existed.
  """

  use Ecto.Migration

  def change do
    alter table(:question_requests) do
      add :answer_history, {:array, :map}
    end

    execute "UPDATE question_requests SET answer_history = '{}'", ""
  end
end
