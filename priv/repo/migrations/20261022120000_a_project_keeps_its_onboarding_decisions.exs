defmodule CodeMySpec.Repo.Migrations.AProjectKeepsItsOnboardingDecisions do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add(:onboarding, :map)
      add(:sources, {:array, :map}, default: [])
    end
  end
end
