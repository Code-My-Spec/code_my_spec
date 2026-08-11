defmodule CodeMySpec.Repo.Migrations.RestoreRequirementsProjectIdentityIndex do
  use Ecto.Migration

  # `20260226183436` created three partial unique indexes on `requirements` —
  # one per entity type. Two of them are in the database; the project one is
  # not, and no migration drops it. So it went by hand and the schema history
  # stopped describing the schema.
  #
  # It matters because it is the identity of a project-scoped requirement.
  # `Topology.node_key/1` keys a node on `{entity_type, entity_id, name}`, and
  # persisting computed nodes means upserting on that key — which needs a unique
  # constraint to conflict against. Component and story nodes have theirs.
  #
  # The predicate is right as written: component and story requirements carry a
  # null `project_id` (4,918 and 255 of 5,191 rows), so `project_id IS NOT NULL`
  # selects only the 18 project-scoped rows, and there are no duplicates among
  # them.
  #
  # `create_if_not_exists` because the databases disagree about whether this
  # already exists, and a repair that only works on the one machine that is
  # missing it is not a repair.
  def up do
    create_if_not_exists unique_index(:requirements, [:project_id, :name],
                           where: "project_id IS NOT NULL",
                           name: :requirements_project_id_name_index
                         )
  end

  # Deliberately not dropped on rollback. `20260226183436` is what creates this
  # index; rolling this migration back and leaving that one applied would put
  # the database back into the drifted state this exists to fix.
  def down, do: :ok
end
