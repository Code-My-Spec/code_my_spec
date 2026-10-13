defmodule CodeMySpec.Repo.Migrations.AQuestionRemembersWhoEscalatedIt do
  use Ecto.Migration

  # The holder that handed a question to the user, so the user's answer goes
  # back to it as well as to the asker.
  def change do
    alter table(:question_requests) do
      add :escalated_by, :string
    end
  end
end
