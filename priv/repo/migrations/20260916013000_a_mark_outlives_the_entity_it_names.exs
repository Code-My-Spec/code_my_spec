defmodule CodeMySpec.Repo.Migrations.AMarkOutlivesTheEntityItNames do
  use Ecto.Migration

  # `graph_invalidations` referenced `components` and `stories` so a mark could
  # not outlive its entity. Backwards: a delete is precisely when the mark
  # matters most, and it is written after the row is gone.
  #
  # Found by `Files.ComponentSync`, which deletes components it no longer sees
  # and broadcasts `{:deleted, component}` after the transaction. The mark's
  # foreign key then had nothing to point at, the insert raised, and it raised
  # *inside* `Components.delete_component/2` — so an experiment that decides
  # nothing was able to break a domain write. Six tests, and it would have been
  # every component deletion in production.
  #
  # Naming the parent instead of the deleted component would have dodged this
  # one call site and left the same trap set for the other fifteen writers. The
  # constraint itself is the mistake: a mark is a claim about an entity at a
  # moment, not a reference to a live row, and the consumer already has to
  # handle an entity that has since departed — `RequirementGraph.departed/2` is
  # the fingerprint path doing exactly that.
  #
  # `project_id` keeps its cascade. A mark for a deleted project is genuinely
  # unreachable work, and nothing announces after a project is gone.
  def up do
    drop constraint(:graph_invalidations, "graph_invalidations_component_id_fkey")
    drop constraint(:graph_invalidations, "graph_invalidations_story_id_fkey")
  end

  def down do
    alter table(:graph_invalidations) do
      modify :component_id, references(:components, type: :binary_id, on_delete: :delete_all),
        from: :binary_id

      modify :story_id, references(:stories, on_delete: :delete_all), from: :bigint
    end
  end
end
