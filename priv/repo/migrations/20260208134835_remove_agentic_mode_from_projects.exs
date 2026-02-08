defmodule CodeMySpec.Repo.Migrations.RemoveAgenticModeFromProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      remove :agentic_mode, :boolean, default: false
    end
  end
end
