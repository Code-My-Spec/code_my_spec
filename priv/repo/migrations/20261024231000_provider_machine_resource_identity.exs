defmodule CodeMySpec.Repo.Migrations.ProviderMachineResourceIdentity do
  use Ecto.Migration

  def change do
    create(unique_index(:devices, [:account_id, :provider, :provider_resource_id]))
  end
end
