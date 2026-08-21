defmodule CodeMySpec.Repo.Migrations.StoriesRememberTheirComponentModule do
  @moduledoc """
  A story remembers which module it belongs to, not only which component row.

  Components are `@derived` — the migration deliberately does not carry them,
  because the destination rebuilds them from the working copy on first sync. The
  import therefore resolves `component_module_name` against the components that
  exist *at import time*, which on a first migration is none of them: the
  working copy has not synced yet. Every story lands with a null `component_id`
  and nothing ever comes back to it.

  Measured 2026-08-21 on the Broken Oaths project: 52 stories, 38 of them linked
  in the source, 0 linked in the destination, against 171 components that
  arrived afterwards and matched by name exactly.

  This column holds the natural key the wire format already uses, so the link
  survives the gap between migrating and syncing rather than depending on the
  two happening in an order the system does not control.

  Nullable with no default, per the project's rule: defaults live on the schema.
  """

  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :component_module_name, :string
    end

    # Every lookup is "stories in this project whose recorded module has now
    # appeared", which is the shape `Files.ComponentSync` runs after each sync.
    create index(:stories, [:project_id, :component_module_name])
  end
end
