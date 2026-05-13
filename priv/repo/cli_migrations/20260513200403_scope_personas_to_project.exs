defmodule CodeMySpec.Repo.Migrations.ScopePersonasToProject do
  use Ecto.Migration

  @moduledoc """
  Personas were account-scoped with the intent that they form a reusable
  library across projects. In practice the disk layout
  (`.code_my_spec/personas/<slug>/`) is per-project, so the design split
  produced personas without research in any project where they didn't apply.

  This migration moves personas to project scope:

    * Adds `project_id` FK and per-project unique index on `slug`
    * Cleans up known noise rows (test personas, duplicates, personas with
      no research and no obvious home)
    * Backfills the remaining personas to the project where their research
      lives on disk

  Notes:
    * `project_id` is left nullable at the DB level for SQLite compatibility;
      the application changeset enforces `validate_required(:project_id)`.
    * `account_id` is left in place as legacy data; future cleanup can drop it.
  """

  def up do
    # 1. Add nullable project_id
    alter table(:personas) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
    end

    flush()

    # 2. Cleanup: drop personas that should not survive the move
    #    - qa-pm, team-lead-tara: explicit test rows
    #    - solo-shipper-sam: dup of 'founder' (same name + description; founder has research)
    #    - small-team-sam: dup of 'coordinator-casey' (identical headline)
    #    - small-team-operator-maya: unique framing but no research, no home
    execute("""
    DELETE FROM persona_stories
    WHERE persona_id IN (
      SELECT id FROM personas
      WHERE slug IN ('qa-pm', 'team-lead-tara', 'solo-shipper-sam', 'small-team-sam', 'small-team-operator-maya')
    );
    """)

    execute("""
    DELETE FROM personas
    WHERE slug IN ('qa-pm', 'team-lead-tara', 'solo-shipper-sam', 'small-team-sam', 'small-team-operator-maya');
    """)

    # 3. Backfill project_id for remaining personas based on where their
    #    research lives on disk (or where they conceptually belong).
    #
    #    MarketMySpec (49d80233-5e7f-4590-8fff-e6af922ce70d): founder, agent, agency-owner
    #    Code My Spec (708492f9-454e-482f-a2eb-be64f0356b87): bootstrap-developer, coordinator-casey
    execute("""
    UPDATE personas SET project_id = '49d80233-5e7f-4590-8fff-e6af922ce70d'
    WHERE slug IN ('founder', 'agent', 'agency-owner');
    """)

    execute("""
    UPDATE personas SET project_id = '708492f9-454e-482f-a2eb-be64f0356b87'
    WHERE slug IN ('bootstrap-developer', 'coordinator-casey');
    """)

    # 4. Swap unique constraint: account_id → project_id
    drop unique_index(:personas, [:account_id, :slug])
    create index(:personas, [:project_id])
    create unique_index(:personas, [:project_id, :slug])
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "Down migration for ScopePersonasToProject is not supported — it deletes data."
  end
end
