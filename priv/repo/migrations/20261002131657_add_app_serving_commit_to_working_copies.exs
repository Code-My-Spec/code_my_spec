defmodule CodeMySpec.Repo.Migrations.AddAppServingCommitToWorkingCopies do
  use Ecto.Migration

  # `app_commit` is the commit the app process launched from. A promote now
  # hot-reloads the app by default, so the code it serves can move on without
  # a launch; this is that commit, so a reloaded app does not read as stale.
  def change do
    alter table(:working_copies) do
      add :app_serving_commit, :string
    end
  end
end
