defmodule CodeMySpec.Repo.Migrations.UpdateRequirementsSchema do
  use Ecto.Migration

  def change do
    alter table(:requirements) do
      # Remove old type enum field
      remove :type

      # Add new artifact_type field
      add :artifact_type, :string, null: false, default: "specification"

      # Add score field for quality scoring
      add :score, :float
    end

    # Create index for filtering by artifact_type
    create index(:requirements, [:artifact_type])

    # Note: checker_module and satisfied_by remain as :string fields
    # They now use CheckerType and SessionType for validation but storage is unchanged
  end
end
