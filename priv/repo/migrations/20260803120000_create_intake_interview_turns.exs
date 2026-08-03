defmodule CodeMySpec.Repo.Migrations.CreateIntakeInterviewTurns do
  use Ecto.Migration

  # One question and its answer. Rows rather than a blob on the plan because
  # the interview runs while the workspace is still coming up — a boot that
  # fails must not cost the visitor the answers they have already given, and
  # each answer has to be durable the moment it is typed.
  def change do
    create table(:intake_interview_turns, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :plan_id, references(:intake_plans, type: :binary_id, on_delete: :delete_all),
        null: false

      # 1-based. The cap on how many questions the visitor answers before they
      # are shown something is a pacing rule, so position is load-bearing.
      add :position, :integer, null: false

      add :question, :text, null: false
      add :answer, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:intake_interview_turns, [:plan_id, :position])
  end
end
