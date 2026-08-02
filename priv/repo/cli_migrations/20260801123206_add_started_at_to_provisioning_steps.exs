defmodule CodeMySpec.Repo.Migrations.AddStartedAtToProvisioningSteps do
  use Ecto.Migration

  # Mirror of the server migration — the CLI loads the same schema, so a
  # column it declares and cli.db lacks fails every select against the table.
  #
  # When a step began, as distinct from when it finished. Ordering claims need
  # both ends: "the repository is in place before the first build needs it" is
  # a comparison between one step finishing and the next starting, and with
  # only completion timestamps it cannot be checked at all.
  def change do
    alter table(:provisioning_steps) do
      add :started_at, :utc_datetime_usec
    end
  end
end
