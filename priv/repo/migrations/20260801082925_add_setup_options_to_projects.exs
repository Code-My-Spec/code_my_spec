defmodule CodeMySpec.Repo.Migrations.AddSetupOptionsToProjects do
  use Ecto.Migration

  # Which parts of setup a project runs. They lived only in the LiveView
  # socket, so every mount reset them to "everything on" — Sam could turn
  # object storage off, come back, and find it on again, then start a run that
  # was not the one he configured.
  #
  # No default here. A default in a migration and a default on the schema
  # drift, and the schema's is the one the application reads; `nil` means
  # "never chosen", which the schema turns into the full set.
  def change do
    alter table(:projects) do
      add :setup_options, {:array, :string}
    end
  end
end
