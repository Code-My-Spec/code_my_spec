defmodule CodeMySpec.Repo.Migrations.AddBootedAtToWorkspaces do
  use Ecto.Migration

  # When this boot attempt started. Distinct from `inserted_at`, which is when
  # the project first had a workspace at all — a retry needs its own clock or
  # the recorded wait is the sum of every attempt, and the whole reason this
  # column exists is to measure how long visitors actually sit through a boot.
  def change do
    alter table(:workspaces) do
      add :booted_at, :utc_datetime
    end
  end
end
