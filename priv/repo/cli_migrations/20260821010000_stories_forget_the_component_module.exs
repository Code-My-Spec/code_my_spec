defmodule CodeMySpec.Repo.Migrations.StoriesForgetTheComponentModule do
  @moduledoc """
  Drops `stories.component_module_name`, added hours earlier in
  `20260821000000` and unnecessary.

  It was there so a migrated story could be linked to its component once that
  component synced. But a component's id is deterministic —
  `UUID.uuid5(namespace, "project:\#{project_id}:module:\#{module_name}")` — so
  the destination can compute the id from the module name the import payload
  already carries, at import time, without the component existing yet and
  without keeping the name.

  Keeping it was the mistake: a story someone re-points afterwards would carry a
  module name that no longer describes it, and nothing would ever correct it.
  Input, not state.
  """

  use Ecto.Migration

  def change do
    drop_if_exists index(:stories, [:project_id, :component_module_name])

    alter table(:stories) do
      remove :component_module_name, :string
    end
  end
end
