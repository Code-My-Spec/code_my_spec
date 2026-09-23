defmodule CodeMySpec.Repo.Migrations.TheCliSchemaCatchesUpToWhatTheSchemasRead do
  @moduledoc """
  Six columns the shared Ecto schemas select and no CLI migration ever created.

  `priv/repo/cli_migrations` stopped at `20260827000000`. The Ecto schemas are
  shared between the cloud app and the CLI release, so every column added to
  Postgres after that date is still in the `SELECT` the CLI sends — and SQLite
  answers `no such column`. `CodeMySpec.Repo.get(Project, id)` has therefore
  been unable to read a project at all:

      ** (Exqlite.Error) no such column: p0.health_route_status

  Which takes down everything that starts by resolving a project, including
  `Projects.resolve_local_project/1` — the function that records a checkout's
  `local_path`, and so the first step of onboarding anything locally.

  Scope was measured rather than guessed: all 69 schemas whose table exists in
  the CLI database, field list against `pragma_table_info`. Four tables were
  short, by six columns in total. Everything else already lined up.

  ## One migration rather than six

  Each column below names the Postgres migration it comes from. Mirroring those
  six files by version number would read as "the CLI set is caught up", and it
  is not — those migrations also create tables and constraints that are
  deliberately not part of the local schema. A single dated catch-up says what
  actually happened, and the next audit is the same `pragma_table_info` diff
  rather than a file-by-file comparison of two sets that are not meant to match.

  ## No defaults, and so no `null: false`

  The Postgres twin of `three_amigos_sealed` carries `default: false`. Defaults
  belong on the schema here, and `Story` already has one, so the column is
  nullable and the existing rows are backfilled — `null: false` without a
  default cannot be added to a populated SQLite table anyway.
  """

  use Ecto.Migration

  def up do
    # 20260830041000_an_agent_records_the_model_it_started_on
    # 20260831090000_an_agent_carries_the_list_of_what_it_may_call
    alter table(:agents) do
      add :model, :string
      add :tools, {:array, :string}
    end

    # 20260830150000_a_harness_reports_whether_health_route_is_there
    # 20260831130000_a_harness_reports_its_own_head_commit
    alter table(:projects) do
      add :health_route_status, :string
      add :head_commit, :string
    end

    # 20260828070805_a_three_amigos_session_is_sealed_once
    alter table(:stories) do
      add :three_amigos_sealed, :boolean
    end

    execute(
      "UPDATE stories SET three_amigos_sealed = 0 WHERE three_amigos_sealed IS NULL",
      "SELECT 1"
    )

    # 20260831120000_a_machine_says_what_else_it_can_do
    alter table(:working_copies) do
      add :machine_tools, {:array, :string}
    end
  end

  def down do
    alter table(:agents) do
      remove :model
      remove :tools
    end

    alter table(:projects) do
      remove :health_route_status
      remove :head_commit
    end

    alter table(:stories) do
      remove :three_amigos_sealed
    end

    alter table(:working_copies) do
      remove :machine_tools
    end
  end
end
