defmodule CodeMySpec.Repo.Migrations.AddVerifiedAtToProvisioningSteps do
  use Ecto.Migration

  # When the step was last checked against its provider, as distinct from when
  # it last ran. A persisted row says what was observed once; it is not
  # evidence the resource still exists, and the difference is exactly what
  # "checked against the provider, not remembered" means.
  def change do
    alter table(:provisioning_steps) do
      add :verified_at, :utc_datetime_usec
    end
  end
end
