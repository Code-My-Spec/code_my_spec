defmodule CodeMySpec.Repo.Migrations.RecordNotificationAnswerers do
  use Ecto.Migration

  def change do
    alter table(:question_requests) do
      add :answered_by_user_id, references(:users, on_delete: :nilify_all)
    end

    alter table(:permission_requests) do
      add :answered_by_user_id, references(:users, on_delete: :nilify_all)
    end
  end
end
