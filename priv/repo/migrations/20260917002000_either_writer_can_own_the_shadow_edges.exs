defmodule CodeMySpec.Repo.Migrations.EitherWriterCanOwnTheShadowEdges do
  use Ecto.Migration

  @moduledoc """
  The last thing keeping the two edge tables from trading places.

  `shadow_requirement_edges` required the entity/name key on both ends and a
  project id, because the event path was the only thing that ever wrote it and
  those were all it had. The pass writes an edge as two row ids and nothing
  else — `requirement_edges` has no other columns — so handing it this table
  would have failed on six not-null constraints.

  Dropping those requirements costs nothing while the event path still writes
  them: it goes on filling every column it filled before. What changes is that
  the table stops describing one writer.

  The keys are not dropped. They are what `diff/1` compares on today, and
  removing them in the same step as making them optional would mean changing
  the comparison and the schema at once, with no way to tell which one broke a
  number. They go when the comparison reads ids on both sides.
  """

  def change do
    alter table(:shadow_requirement_edges) do
      modify :project_id, :uuid, null: true, from: {:uuid, null: false}
      modify :from_entity_type, :string, null: true, from: {:string, null: false}
      modify :from_entity_id, :string, null: true, from: {:string, null: false}
      modify :from_name, :string, null: true, from: {:string, null: false}
      modify :to_entity_type, :string, null: true, from: {:string, null: false}
      modify :to_entity_id, :string, null: true, from: {:string, null: false}
      modify :to_name, :string, null: true, from: {:string, null: false}
    end
  end
end
