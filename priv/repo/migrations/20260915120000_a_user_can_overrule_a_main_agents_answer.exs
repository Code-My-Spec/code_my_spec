defmodule CodeMySpec.Repo.Migrations.AUserCanOverruleAMainAgentsAnswer do
  @moduledoc """
  An answer could not say who gave it, so it could not be overruled.

  Story 1052, criteria 3219, 3220 and 3222. `answer_question_request/2` had no
  notion of an answerer: the second call was refused as
  `{:already_resolved, status}` whoever made it and whoever made the first, so
  the user could not correct a main agent that had answered wrongly, and the
  collecting agent could not tell a reading of the records from the user's own
  intent.

  `answered_by` carries who gave the current answer, as distinct from `holder`,
  which says who it is waiting *on*. `overruled` is separate because
  `answered_by` cannot express it: after an override it correctly reads `user`,
  identical to an ordinary first answer, and 3220 needs the agent to hear that
  an earlier answer existed and was replaced.

  `user` is the backfill for every existing row, and it is right rather than
  convenient: nothing answered before this had passed through a main agent,
  because there was no main agent to pass through. None of them was overruled
  for the same reason.

  No column defaults — the schema carries them, so the code writing rows is
  what decides, and a row inserted without one fails loudly here instead of
  quietly acquiring an answerer nobody chose. Same reasoning as
  `20260911000000_a_question_says_who_is_holding_it`, which added `holder` to
  this table.
  """

  use Ecto.Migration

  def change do
    alter table(:question_requests) do
      add :answered_by, :string
      add :overruled, :boolean
    end

    execute "UPDATE question_requests SET answered_by = 'user', overruled = false", ""
  end
end
