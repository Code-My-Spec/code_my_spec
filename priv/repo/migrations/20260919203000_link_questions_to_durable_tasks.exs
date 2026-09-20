defmodule CodeMySpec.Repo.Migrations.LinkQuestionsToDurableTasks do
  use Ecto.Migration

  def change do
    alter table(:question_requests) do
      add :task_id, :string
    end
  end
end
