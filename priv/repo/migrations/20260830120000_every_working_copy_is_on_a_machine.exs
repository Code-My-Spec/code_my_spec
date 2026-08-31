defmodule CodeMySpec.Repo.Migrations.EveryWorkingCopyIsOnAMachine do
  @moduledoc """
  Story 958. `working_copies.device_id` and `devices.kind` stop being nullable.

  A checkout is identified by `{project, device, root}` — two machines share a
  path constantly, every container at `/workspace/app` — so a copy with no
  machine cannot be told apart from one somewhere else, and cannot be
  recognised on the next join either. It also cannot answer where it is
  running, which decides whether an agent may spend a subscription (local) or
  must use an API key (cloud).

  Nullable was a deliberate concession to harnesses too old to announce a
  device. That concession has outlived its reason: the join has carried a
  device for a while, and onboarding now reads the identity the machine holds —
  announcing one if it has none — so both mint paths supply it.

  ## The rows this fixes were cruft, and are backfilled rather than deleted

  Deleting is not available: nine tables carry a `working_copy_id`, including
  files, problems, issues, requirements, sessions and agents, plus
  `projects.default_working_copy_id`. On dev one of the device-less copies had
  a live agent on it.

  So each is attached to the machine that already carries the most copies for
  its account — which on any real installation is that account's actual
  machine, and is what John asked for on the database this was written against.
  An account with no device at all gets one minted, labelled for what it is, so
  the constraint has something true to point at rather than a row invented to
  satisfy it silently.

  `devices.kind` gets the same treatment, so "which machine" and "what kind of
  machine" are answerable together and nothing downstream has to carry a third
  state. Every device that predates the column is a local one — cloud devices
  arrived with it — so the backfill is a historical fact rather than a default
  standing in for one. The default for machines that announce without saying
  lives on the schema, not here: a migration default would silently fill the
  column for writers that bypass the changeset, which is the opposite of making
  the value deliberate.
  """

  use Ecto.Migration

  def up do
    # Ordered before the working-copy backfill: a copy attached to a device
    # with no kind would satisfy one constraint and not the other.
    execute("UPDATE devices SET kind = 'local' WHERE kind IS NULL")

    # One device per account that has none, so the join below always finds a
    # row. `account_id` stays nullable on `devices` — a shared box belongs to
    # nobody and that is a real state — but an account whose copies need
    # attributing is not that case.
    execute("""
    INSERT INTO devices (id, hostname, label, kind, account_id, last_seen_at, inserted_at, updated_at)
    SELECT gen_random_uuid(),
           'unknown',
           'Unattributed — recorded before checkouts reported their machine',
           'local',
           p.account_id,
           NULL,
           NOW(),
           NOW()
    FROM working_copies w
    JOIN projects p ON p.id = w.project_id
    WHERE w.device_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM devices d WHERE d.account_id = p.account_id)
    GROUP BY p.account_id
    """)

    # The account's busiest device, which is its real machine wherever there is
    # one. `hostname` breaks the tie so a re-run picks the same row.
    execute("""
    UPDATE working_copies w
    SET device_id = (
      SELECT d.id
      FROM devices d
      JOIN projects p ON p.id = w.project_id
      LEFT JOIN working_copies c ON c.device_id = d.id
      WHERE d.account_id = p.account_id
      GROUP BY d.id, d.hostname
      ORDER BY COUNT(c.id) DESC, d.hostname ASC
      LIMIT 1
    )
    WHERE w.device_id IS NULL
    """)

    # Anything still unattributed has no account to attach it to — a project
    # whose account is gone. Nothing can be said about where it ran, and the
    # rows it holds are unreachable through any account's pages.
    #
    # `last_seen_at IS NOT NULL` keeps `WorkingCopies.ensure_default/1`'s row:
    # see the constraint below.
    execute("DELETE FROM working_copies WHERE device_id IS NULL AND last_seen_at IS NOT NULL")

    alter table(:devices) do
      modify :kind, :string, null: false
    end

    # Dropped by name first: `modify` with a `references` adds a constraint, it
    # does not replace one, so leaving the old `nilify_all` in place fails with
    # `duplicate_object` on a name Postgres derived rather than anything the
    # migration says.
    drop(constraint(:working_copies, "working_copies_device_id_fkey"))

    # The machine goes, its checkouts go with it — John's call, and it reads
    # better than it sounds because the tables hanging off a working copy
    # already say what should happen to each of them. `files`, `requirements`,
    # `analysis_runs` and `file_analyses` cascade: every one is a projection of
    # a disk, and the disk is gone. `agents`, `issues`, `problems`, `sessions`
    # and `projects.default_working_copy_id` are `SET NULL`: those are records
    # of work that really happened and outlive the checkout that did it.
    #
    # So the fear criterion 2848 was written against — "a cascade delete would
    # take the record of work that was really done because the box it sat on
    # went away" — is answered by those rules rather than by keeping a
    # machine-less copy around to hold the place. The record survives; the
    # projection of a directory nobody has any more does not.
    alter table(:working_copies) do
      modify :device_id, references(:devices, type: :binary_id, on_delete: :delete_all)
    end

    # NOT NULL for every checkout, with the one carve-out named rather than
    # left to a nullable column.
    #
    # `WorkingCopies.ensure_default/1` mints a row per project — "the project's
    # working copy" — as a nil object for writers that legitimately have no
    # checkout: a mix task, the web UI, a fixture. It is not on a machine
    # because it is not a checkout, and no machine ever joins as it. Its own
    # doc already names what tells it apart: `last_seen_at` stays nil, and a
    # real copy has one from the moment it is created.
    #
    # So the invariant that matters is not "every row has a device" but "every
    # row that has ever been seen has one", which is what this says. A plain
    # NOT NULL would have forced the nil object to invent a machine, and
    # inventing a machine is what the whole change is trying to stop.
    create constraint(:working_copies, :seen_copies_are_on_a_machine,
             check: "device_id IS NOT NULL OR last_seen_at IS NULL"
           )
  end

  def down do
    drop(constraint(:working_copies, :seen_copies_are_on_a_machine))
    drop(constraint(:working_copies, "working_copies_device_id_fkey"))

    alter table(:working_copies) do
      modify :device_id, references(:devices, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:devices) do
      modify :kind, :string, null: true
    end
  end
end
