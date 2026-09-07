defmodule CodeMySpec.Repo.Migrations.AStepBelongsToOneEnvironmentOrTheWholeProject do
  use Ecto.Migration

  def change do
    alter table(:provisioning_steps) do
      # No default — matches the existing columns' own rule. Null means this
      # step is project-wide (repository, server, domain, dns, email,
      # inbound); a name means this row is one environment's instance of a
      # step that runs independently per environment (secrets, deploy, tls,
      # storage, backups, content, widget, callback_credential).
      add :environment, :string
    end

    drop unique_index(:provisioning_steps, [:project_id, :key])

    # Two partial indexes rather than one over all three columns: Postgres
    # treats NULL <> NULL for uniqueness, so a single index on
    # (project_id, key, environment) would let a project-wide step
    # accumulate duplicate rows. One row per (project, key) among the
    # project-wide steps, and separately one row per (project, key,
    # environment) among the per-environment ones.
    create unique_index(:provisioning_steps, [:project_id, :key],
             where: "environment IS NULL",
             name: :provisioning_steps_project_id_key_no_environment_index
           )

    create unique_index(:provisioning_steps, [:project_id, :key, :environment],
             where: "environment IS NOT NULL",
             name: :provisioning_steps_project_id_key_environment_index
           )

    # Existing rows for the keys becoming per-environment are a single
    # verdict blended across every environment that step's run touched —
    # there is no reliable way to attribute one state back to one
    # environment after the fact. A step's persisted state is a claim to
    # re-verify, never a source of truth (Step's own moduledoc, criterion
    # 7970): the next page load re-checks each of these against its
    # provider, so deleting rather than guessing costs a page load, and
    # guessing wrong would tell someone a specific environment failed when
    # it did not.
    execute(
      "DELETE FROM provisioning_steps WHERE key IN ('secrets','deploy','tls','storage','backups','content','widget','callback_credential')",
      ""
    )
  end
end
