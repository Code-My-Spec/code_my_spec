defmodule CodeMySpec.Repo.Migrations.RequirementsBelongToTheCopyThatComputedThem do
  use Ecto.Migration

  @moduledoc """
  A requirement's verdict is now keyed by the working copy that reached it.

  ## What was wrong

  `satisfied` was one row per (owner, name) for the whole project, computed from
  `Preloader.load/1` — which scopes its file query to the *calling* scope's
  working copy. So every checkout that synced overwrote the entire project's
  graph with its own partial view of the filesystem.

  Measured here before the change: 177 working copies on this project, **3 with
  any file rows at all**. Any of the other 174 computing the graph wrote
  `satisfied = false` for every file-based requirement on the project. Stories
  891, 892, 956 and 958 all read `bdd_specs_exist = false` with
  `details: {"reason": "bdd_spec file missing"}` while three separate copies
  each held 10-13 of exactly those files.

  It stayed invisible because `bdd_specs_passing` is `field_true` on a story
  column rather than on files, so it stayed satisfied throughout — a story
  reading "specs are green" and "specs do not exist" at the same time looks like
  one story's bug rather than a systemic one.

  ## NULLS NOT DISTINCT

  The UI path computes with no working copy on purpose (`Preloader.load/1` logs
  it and blends every checkout's files). Those rows carry a null
  `working_copy_id`, and Postgres treats nulls as distinct in a unique index by
  default — so the old identity would stop constraining them and the UI would
  insert a fresh duplicate row on every render. Postgres 15 added
  `NULLS NOT DISTINCT`, which makes "no working copy" a single value like any
  other. This server is 15.18.

  ## Why delete_all

  A working copy's requirement rows are derived from that copy, exactly like its
  files and problems. When it is offboarded they go with it — the same rule
  `WorkingCopies.offboard/2` already applies one level down, and without the
  cascade an offboarded copy's verdicts would outlive the copy that reached
  them.
  """

  def up do
    alter table(:requirements) do
      add :working_copy_id,
          references(:working_copies, type: :binary_id, on_delete: :delete_all)
    end

    create index(:requirements, [:working_copy_id])

    # The old identity, replaced rather than added to: a unique index that does
    # not mention the working copy is the constraint that made one copy's
    # verdict overwrite another's.
    drop unique_index(:requirements, [:component_id, :name],
           where: "component_id IS NOT NULL",
           name: :requirements_component_id_name_index
         )

    drop unique_index(:requirements, [:story_id, :name],
           where: "story_id IS NOT NULL",
           name: :requirements_story_id_name_index
         )

    drop unique_index(:requirements, [:project_id, :name],
           where: "project_id IS NOT NULL",
           name: :requirements_project_id_name_index
         )

    execute """
    CREATE UNIQUE INDEX requirements_component_id_name_index
      ON requirements (component_id, name, working_copy_id) NULLS NOT DISTINCT
      WHERE component_id IS NOT NULL
    """

    execute """
    CREATE UNIQUE INDEX requirements_story_id_name_index
      ON requirements (story_id, name, working_copy_id) NULLS NOT DISTINCT
      WHERE story_id IS NOT NULL
    """

    execute """
    CREATE UNIQUE INDEX requirements_project_id_name_index
      ON requirements (project_id, name, working_copy_id) NULLS NOT DISTINCT
      WHERE project_id IS NOT NULL
    """
  end

  def down do
    execute "DROP INDEX requirements_component_id_name_index"
    execute "DROP INDEX requirements_story_id_name_index"
    execute "DROP INDEX requirements_project_id_name_index"

    # Every existing row would collide on the way back, because losing the
    # working copy from the key is exactly what makes them duplicates. Keeping
    # one per (owner, name) is the only thing the old shape can hold, and which
    # one survives is arbitrary — the same arbitrariness this migration removes.
    execute """
    DELETE FROM requirements r
    USING requirements keep
    WHERE keep.name = r.name
      AND r.id > keep.id
      AND (
        (r.component_id IS NOT NULL AND r.component_id = keep.component_id) OR
        (r.story_id IS NOT NULL AND r.story_id = keep.story_id) OR
        (r.project_id IS NOT NULL AND r.project_id = keep.project_id)
      )
    """

    create unique_index(:requirements, [:component_id, :name],
             where: "component_id IS NOT NULL",
             name: :requirements_component_id_name_index
           )

    create unique_index(:requirements, [:story_id, :name],
             where: "story_id IS NOT NULL",
             name: :requirements_story_id_name_index
           )

    create unique_index(:requirements, [:project_id, :name],
             where: "project_id IS NOT NULL",
             name: :requirements_project_id_name_index
           )

    drop index(:requirements, [:working_copy_id])

    alter table(:requirements) do
      remove :working_copy_id
    end
  end
end
