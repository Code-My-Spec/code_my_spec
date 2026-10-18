defmodule CodeMySpec.Repo.Migrations.DropRetiredAnalyzerSettings do
  use Ecto.Migration

  # Problems gate only at promotion now, so these per-analyzer stop modes
  # no longer do anything.
  def change do
    alter table(:project_configurations) do
      remove(:compile_warnings, :string)
      remove(:credo, :string)
      remove(:exunit, :string)
      remove(:spex, :string)
    end
  end
end
