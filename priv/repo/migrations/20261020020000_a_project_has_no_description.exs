defmodule CodeMySpec.Repo.Migrations.AProjectHasNoDescription do
  use Ecto.Migration

  # Issue ba08757e: the summary was a display field nothing kept true, and the
  # one place it reached an agent (design prompts) said things that had gone
  # stale. John, 2026-10-20: remove it.
  def change do
    alter table(:projects) do
      remove(:description, :string)
    end
  end
end
