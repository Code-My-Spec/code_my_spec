defmodule CodeMySpec.Repo.Migrations.QaInvalidationsAllowNilUser do
  use Ecto.Migration

  # Local-app invalidations (via the LiveView story page on port 4004)
  # have no authenticated user — `Invalidations.invalidate/3` records
  # `invalidated_by_user_id: nil` in that case. The CLI migration
  # already allows nil; align the server schema to match so the local
  # path doesn't crash on a NOT NULL violation.

  def change do
    alter table(:qa_invalidations) do
      modify :invalidated_by_user_id, references(:users, on_delete: :nilify_all),
        null: true,
        from: {references(:users, on_delete: :nothing), null: false}
    end
  end
end
