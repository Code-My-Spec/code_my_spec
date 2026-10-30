defmodule CodeMySpec.Repo.Migrations.StoreProvisioningExceptionTrace do
  use Ecto.Migration

  def change do
    alter table(:provisioning_steps) do
      add :exception_trace, :text
    end
  end
end
