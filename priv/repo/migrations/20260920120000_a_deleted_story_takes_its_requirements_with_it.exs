defmodule CodeMySpec.Repo.Migrations.ADeletedStoryTakesItsRequirementsWithIt do
  @moduledoc """
  `requirements.story_id` had no foreign key, so a deleted story left its rows
  behind forever.

  `component_id` has had `ON DELETE CASCADE` since the table was written, which
  is why the same failure never showed up for components. Stories were the
  asymmetry.

  What the rows then do is worse than merely existing. `Preloader` cannot load a
  story that is gone, so `Projection.rehydrate/2` resolves none of them and
  drops every one; the read is a strict subset of what the publish counted;
  `served_graph/3` refuses the short read and recomputes the whole graph. That
  happens on *every* read, permanently, because no later pass will ever visit an
  entity that does not exist — which is the one thing `delete_departed/4` needs
  in order to reap.

  Measured before this ran: 385 rows across 60 stories that no longer exist.

  `requirement_edges` already cascades from `requirements`, so the edges go with
  the rows and need nothing here.
  """

  use Ecto.Migration

  def up do
    # Orphans first: the constraint cannot be added while rows violate it.
    #
    # Safe to delete rather than repair, because these rows are derived. The
    # graph is recomputed from Files and Problems, so anything genuinely still
    # wanted is rewritten by the next pass — and nothing here is wanted, since
    # every one of them names a story that does not exist.
    execute("""
    DELETE FROM requirements r
    WHERE r.story_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM stories s WHERE s.id = r.story_id)
    """)

    execute("""
    DELETE FROM shadow_requirements r
    WHERE r.story_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM stories s WHERE s.id = r.story_id)
    """)

    alter table(:requirements) do
      modify :story_id, references(:stories, on_delete: :delete_all), from: :bigint
    end

    alter table(:shadow_requirements) do
      modify :story_id, references(:stories, on_delete: :delete_all), from: :bigint
    end
  end

  def down do
    alter table(:requirements) do
      modify :story_id, :bigint, from: references(:stories, on_delete: :delete_all)
    end

    alter table(:shadow_requirements) do
      modify :story_id, :bigint, from: references(:stories, on_delete: :delete_all)
    end
  end
end
