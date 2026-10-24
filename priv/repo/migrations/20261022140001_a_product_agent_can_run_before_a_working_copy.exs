defmodule CodeMySpec.Repo.Migrations.AProductAgentCanRunBeforeAWorkingCopy do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add(:execution_mode, :string, default: "working_copy", null: false)
    end

    create(
      unique_index(:agents, [:project_id],
        name: :agents_one_detached_product_per_project,
        where: "execution_mode = 'detached' AND role = 'product' AND retired_at IS NULL"
      )
    )
  end
end
