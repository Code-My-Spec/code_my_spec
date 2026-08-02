defmodule CodeMySpec.Repo.Migrations.CreateProvisioningSteps do
  use Ecto.Migration

  def change do
    create table(:provisioning_steps) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :key, :string, null: false
      add :state, :string, null: false
      add :position, :integer, null: false

      # The provider's own words, kept verbatim so an escalation can name the
      # permission that was missing rather than "the domain step failed".
      add :attempted, :text
      add :provider_error, :text
      add :paused_instructions, :text

      # No column default — defaults belong on the schema, where the
      # embeds_many already starts at []. A default here would be a second
      # source of truth that only fires on raw inserts.
      add :resources, :map

      timestamps(type: :utc_datetime)
    end

    # One row per project per step — the sequence is a fixed set of named
    # steps, and re-running one converges rather than appending a second.
    create unique_index(:provisioning_steps, [:project_id, :key])

    # The status page reads the whole sequence in order for one project.
    create index(:provisioning_steps, [:project_id, :position])
  end
end
