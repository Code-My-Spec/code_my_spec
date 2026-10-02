defmodule CodeMySpec.Repo.Migrations.ProjectsRecordWhenTheirComponentsWereFrozen do
  use Ecto.Migration

  # Components as records, step 3 (3aeb66cf): when a project's components were
  # frozen into records. Unset until the one-time freeze runs for it.
  def change do
    alter table(:projects) do
      add :components_authored_at, :utc_datetime_usec
    end
  end
end
