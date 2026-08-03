defmodule CodeMySpec.Repo.Migrations.AddStepToWorkspaces do
  use Ecto.Migration

  # The boot phase the container last announced. Stored rather than derived on
  # read so a reconnecting visitor sees the bar where it was, not back at zero.
  def change do
    alter table(:workspaces) do
      add :step, :string
    end
  end
end
