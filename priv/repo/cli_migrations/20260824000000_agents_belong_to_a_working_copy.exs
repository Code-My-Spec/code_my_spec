defmodule CodeMySpec.Repo.Migrations.AgentsBelongToAWorkingCopy do
  @moduledoc """
  An agent belongs to a working copy by its id, not by a matching path string.

  `agents.harness_id` has been on the row since the table was created and
  nothing keyed on it. The join was `agents.working_copy == harnesses.root` —
  two reported strings compared to each other, which is the same mistake the
  hook surface stopped making when it moved to id addressing.

  Two ways it goes wrong. A copy that normalises its path differently
  (a symlink, a trailing slash, `/private/tmp` versus `/tmp`) silently forms its
  own group and the agent lands on a working copy that does not exist. And two
  harness rows can share a root — there are five such groups on this project
  today — so a path match is ambiguous exactly where the answer matters.

  `working_copy` stays. It is where the agent actually runs, which `PiConfig`
  needs to mint a config directory outside it and the conversation key needs to
  match what a lane pushes under. Same status as `harnesses.root`: reported, and
  no longer identifying.

  ## Backfill is best-effort on purpose

  Nothing here is in production. Rows whose `harness_id` names a harness that no
  longer exists are nulled rather than deleted — losing the link is recoverable,
  losing the row is not — and the rest are matched by root where that is
  unambiguous. The column stays nullable in the database and required in the
  changeset, which is how `harnesses` treats `root`: old rows keep whatever they
  have, and nothing new can be written without one.
  """

  use Ecto.Migration

  def up do
    # A dangling id would fail the constraint below. Null it first: the row is
    # still evidence that an agent ran, and which copy it ran on is the part
    # that is genuinely lost.
    execute("""
    UPDATE agents SET harness_id = NULL
    WHERE harness_id IS NOT NULL
      AND harness_id NOT IN (SELECT id FROM harnesses)
    """)

    # Where a root names exactly one harness on the same project, that is the
    # answer. Where it names several, no guess is better than another and the
    # row keeps a null.
    execute("""
    UPDATE agents a SET harness_id = h.id
    FROM harnesses h
    WHERE a.harness_id IS NULL
      AND h.project_id = a.project_id
      AND h.root = a.working_copy
      AND (SELECT count(*) FROM harnesses x
           WHERE x.project_id = a.project_id AND x.root = a.working_copy) = 1
    """)

    alter table(:agents) do
      modify :harness_id, references(:harnesses, type: :binary_id, on_delete: :nilify_all),
        from: :binary_id
    end

    # The join the page makes on every render, and the lookup the reconcile
    # makes per reported lane.
    create index(:agents, [:harness_id, :role])
  end

  def down do
    drop index(:agents, [:harness_id, :role])

    alter table(:agents) do
      modify :harness_id, :binary_id,
        from: references(:harnesses, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
