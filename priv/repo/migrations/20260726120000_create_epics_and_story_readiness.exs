defmodule CodeMySpec.Repo.Migrations.CreateEpicsAndStoryReadiness do
  use Ecto.Migration

  def change do
    create table(:epics, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :account_id, :binary_id
      add :project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:epics, [:project_id, :name])
    create unique_index(:epics, [:project_id, :slug])
    create index(:epics, [:account_id])

    alter table(:stories) do
      # Epics are organizational only — a story belongs to at most one, and
      # losing an epic must never destroy the story.
      add :epic_id, references(:epics, type: :binary_id, on_delete: :nilify_all)

      # No default here on purpose — defaults live on the schema.
      add :ready_for_dev, :boolean

      # The user-story sentence and the agent's working notes are separate
      # fields; `description` stays for existing readers.
      add :story, :text
      add :notes, :text
    end

    create index(:stories, [:epic_id])

    # Grandfathering: stories that predate the flag are ready for development,
    # so the existing queue keeps running after the upgrade.
    execute "UPDATE stories SET ready_for_dev = true", "SELECT 1"

    # Copy the story sentence into its own field; notes start empty.
    execute "UPDATE stories SET story = description", "SELECT 1"
  end
end
