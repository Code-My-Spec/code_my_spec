defmodule CodeMySpec.Repo.Migrations.ValidationHoldsHaveOwnersAndTerminalHandoffs do
  use Ecto.Migration

  def change do
    create table(:validation_holds, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:project_id, references(:projects, type: :uuid, on_delete: :delete_all), null: false)
      add(:owner_agent_id, :binary_id, null: false)
      add(:reason, :text, null: false)
      add(:affected_copy_ids, {:array, :uuid}, null: false)
      add(:authorized_copy_id, :binary_id)
      add(:source, :string)
      add(:args, {:array, :string}, default: [], null: false)
      add(:next_agent_id, :binary_id, null: false)
      add(:status, :string, null: false)
      add(:run_id, references(:analysis_runs, on_delete: :nilify_all))
      add(:outcome, :map)
      add(:history, :map, default: %{"events" => []}, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:validation_holds, [:project_id],
        where: "status != 'released'",
        name: :validation_holds_one_open_per_project
      )
    )

    create(index(:validation_holds, [:run_id]))
  end
end
