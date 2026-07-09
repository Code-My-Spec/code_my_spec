defmodule CodeMySpec.Repo.Migrations.CreateQuestionRequests do
  use Ecto.Migration

  def change do
    create table(:question_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :title, :string
      # A list of question maps: %{"question", "header", "options" => [%{"label","description"}], "multiSelect"}.
      add :questions, :jsonb, null: false, default: "[]"
      add :status, :string, null: false, default: "pending"
      # Map of question text => selected label (or list of labels for multi-select).
      add :answers, :jsonb, null: false, default: "{}"

      timestamps(type: :utc_datetime)
    end

    create index(:question_requests, [:user_id])
    create index(:question_requests, [:status])
  end
end
