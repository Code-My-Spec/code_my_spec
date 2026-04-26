defmodule CodeMySpec.Repo.Migrations.CliFilesMtimeUsec do
  use Ecto.Migration

  def up do
    alter table(:files) do
      modify :mtime, :utc_datetime_usec, from: :utc_datetime
    end
  end

  def down do
    alter table(:files) do
      modify :mtime, :utc_datetime, from: :utc_datetime_usec
    end
  end
end
