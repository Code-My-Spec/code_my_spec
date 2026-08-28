defmodule CodeMySpec.Repo.Migrations.AShapingConversationSurvivesAReload do
  use Ecto.Migration

  @moduledoc """
  The shaping turns and the question awaiting an answer, on the row.

  `Intake.transcript/3`'s own doc says the conversation is "derived from the plan
  row rather than accumulated anywhere, which is what makes it survive both a
  reload and the navigation through the signup gate". That was true of the
  description and of nothing else: the turns and the pending question lived in
  socket assigns, so a reload kept the row and lost the conversation.

  What made it visible was resuming. A returning visitor was re-asked by calling
  the model again with no turns — so every reload produced a *different*
  question from the same first message, and reloading twice asked twice. The
  fix is not to re-ask more carefully; it is to have something to restore.

  `:map` rather than an embed, because these are two strings per turn that
  nothing queries and nothing joins. A schema for them would be a second place
  the shape of a turn is written down.
  """

  def change do
    alter table(:intake_plans) do
      add :shaping_turns, {:array, :map}, null: false, default: []
      add :pending_question, :text
    end
  end
end
