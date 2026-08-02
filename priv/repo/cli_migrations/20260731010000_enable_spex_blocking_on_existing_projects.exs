defmodule CodeMySpec.Repo.Migrations.EnableSpexBlockingOnExistingProjects do
  use Ecto.Migration

  def change do
    # Existing projects on, new projects off.
    #
    # The schema default stays `:off` so a project created tomorrow starts
    # quiet — it has no story that has ever gone green, so there is nothing
    # for enforcement to protect. Projects that already exist are the
    # opposite case: they have shipped stories, and the per-story
    # specs-ready latch now makes blocking safe for them in a way it never
    # was before (a spex failure on a story still mid-build stays
    # advisory).
    #
    # Only `off`/NULL rows move. Anyone who deliberately chose
    # `dont_block` or `block_changed` keeps it — this is a default being
    # corrected, not a preference being overridden.
    execute(
      "UPDATE project_configurations SET spex = 'block_all' WHERE spex IS NULL OR spex = 'off'",
      "SELECT 1"
    )
  end
end
