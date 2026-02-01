defmodule CodeMySpec.Repo.Migrations.DropStoriesComponentFk do
  use Ecto.Migration

  @doc """
  Drop the foreign key constraint on stories.component_id.

  Stories can reference components that only exist in CLI environments (local spec files),
  not necessarily in the server database. The component_id is an informational reference,
  not a strict database relationship.
  """
  def change do
    drop constraint(:stories, :stories_component_id_fkey)
  end
end
