defmodule CodeMySpec.Repo.Migrations.AStorySaysWhichCheckoutItIsBuiltOn do
  use Ecto.Migration

  @moduledoc """
  The assignment axis lands on the story, and the epic loses its copy.

  Story 895's gap in one line: `files` and `problems` carry a working copy;
  stories carried nothing, so there was no way to say which checkout a story is
  built on. `get_next_requirement` therefore had no notion of a working copy at
  all, and three agents given an epic pulled whatever the project offered next.

  ## Why the story and not the epic

  An epic already had `working_copy_id`, added 2026-08-25, and it was recorded
  and never read: nothing consulted it to decide what an agent is offered, and
  the requirement graph has no notion of epics anywhere. So the column named a
  routing that nothing performed — which is worse than absent, because an agent
  asked to release an epic reasons to the edge of what exists and then invents
  the step that would bridge the gap.

  John: *"assigning an epic to a working copy doesn't make any sense because an
  epic is just basically a convenience measure to act on multiple stories ...
  these assignments need to go into the story because that's how the graph
  works, and that's what the graph should be grained on anyway."*

  So the binding moves down a level, to the grain the graph is already built on.
  Assigning an epic still works — it writes through to that epic's stories — but
  it is a convenience over the real axis rather than a second one beside it.

  ## Nullable, and staying that way

  Null is not missing data. It is the shared backlog: *"if a harness is assigned
  stories, it should get its assigned stories and all unassigned stories."*
  Assignment narrows what a working copy is refused for and never narrows what
  it can see, which is what lets this column land empty and change nothing until
  somebody assigns something.

  `nilify_all` for the same reason. A checkout being torn down returns its
  stories to the shared pool; deleting the work because the directory went away
  would be the destructive reading of a routine event.
  """

  def up do
    alter table(:stories) do
      add :working_copy_id, references(:working_copies, type: :binary_id, on_delete: :nilify_all)
    end

    # The selection query: "this copy's stories plus the unassigned ones",
    # asked on every `get_next_requirement`.
    create index(:stories, [:project_id, :working_copy_id])

    # Carry the two dispatched epics' placements down to their stories before
    # the column they came from goes. Nine stories on "War and Occupation"
    # today — the epic this story exists to get moving.
    execute """
    UPDATE stories s
    SET working_copy_id = e.working_copy_id
    FROM epics e
    WHERE s.epic_id = e.id AND e.working_copy_id IS NOT NULL
    """

    alter table(:epics) do
      remove :working_copy_id
    end
  end

  def down do
    alter table(:epics) do
      add :working_copy_id, :binary_id
    end

    # Back up a level, taking any member story's copy. Lossy on purpose: two
    # stories of one epic on different checkouts is expressible in the new shape
    # and not in the old one, which is most of the reason for the move.
    execute """
    UPDATE epics e
    SET working_copy_id = (
      SELECT s.working_copy_id
      FROM stories s
      WHERE s.epic_id = e.id AND s.working_copy_id IS NOT NULL
      LIMIT 1
    )
    """

    drop index(:stories, [:project_id, :working_copy_id])

    alter table(:stories) do
      remove :working_copy_id
    end
  end
end
