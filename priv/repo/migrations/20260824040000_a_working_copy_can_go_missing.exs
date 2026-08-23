defmodule CodeMySpec.Repo.Migrations.AWorkingCopyCanGoMissing do
  use Ecto.Migration

  @moduledoc """
  Working copy presence stops being a guess about time and becomes an
  observation about a path.

  `path_missing_since` is stamped when the harness serving a copy reports that
  its checkout is no longer at its root, and nulled the moment it reports it
  back. Nil therefore covers two states — present, and never asked — which is
  correct here: neither is a reason to warn anybody.

  `working_copy_idle_hours` goes with the model it configured. Nothing reads a
  threshold any more, and a setting on the configuration page that changes
  nothing is worse than no setting at all.
  """

  def up do
    alter table(:working_copies) do
      add :path_missing_since, :utc_datetime_usec
    end

    alter table(:project_configurations) do
      remove :working_copy_idle_hours
    end
  end

  def down do
    alter table(:working_copies) do
      remove :path_missing_since
    end

    alter table(:project_configurations) do
      add :working_copy_idle_hours, :integer
    end
  end
end
