defmodule CodeMySpec.Repo.Migrations.AnAgentHoldsItsOwnStoryAndEpic do
  @moduledoc """
  The team's story and epic move from the working copy to its agents
  (a31f1cd6 step 3). Each agent holds `story_id` and `epic_id`; the coding and
  QA agents on a copy are assigned a story together and that is the only
  record. John: "we don't have to record the active story on the copy. It just
  blows through." So `working_copies.active_story_id` goes, after its value is
  copied onto every agent on the copy.
  """

  use Ecto.Migration

  def up do
    alter table(:agents) do
      add :story_id, references(:stories, on_delete: :nilify_all)
      add :epic_id, references(:epics, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:agents, [:story_id])
    create index(:agents, [:epic_id])

    # The team — coding and QA — on a feature copy takes the story and its
    # epic; product takes only the epic. Main never holds a story, and nothing
    # on the main copy does.
    execute("""
    UPDATE agents a SET story_id = s.id, epic_id = s.epic_id
    FROM working_copies wc
    JOIN stories s ON s.id = wc.active_story_id
    WHERE a.working_copy_id = wc.id AND wc.main IS NOT TRUE AND a.role IN ('coding', 'qa')
    """)

    execute("""
    UPDATE agents a SET epic_id = s.epic_id
    FROM working_copies wc
    JOIN stories s ON s.id = wc.active_story_id
    WHERE a.working_copy_id = wc.id AND wc.main IS NOT TRUE AND a.role = 'product'
    """)

    drop index(:working_copies, [:active_story_id])

    alter table(:working_copies) do
      remove :active_story_id
    end
  end

  def down do
    alter table(:working_copies) do
      add :active_story_id, references(:stories, on_delete: :nilify_all)
    end

    create index(:working_copies, [:active_story_id])

    execute("""
    UPDATE working_copies wc SET active_story_id = a.story_id
    FROM agents a
    WHERE a.working_copy_id = wc.id AND a.story_id IS NOT NULL
      AND a.role IN ('coding', 'qa')
    """)

    drop index(:agents, [:epic_id])
    drop index(:agents, [:story_id])

    alter table(:agents) do
      remove :epic_id
      remove :story_id
    end
  end
end
