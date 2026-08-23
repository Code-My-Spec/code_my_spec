defmodule CodeMySpec.Repo.Migrations.DevicesAreTheMachinesCopiesSitOn do
  @moduledoc """
  The machine a working copy is on.

  The third level, and the one that was missing. A device runs a harness; a
  harness serves one or more working copies; a working copy runs one or more
  agents. Only the middle two existed, so four questions had no answer:

    * **Is this copy on my laptop or in the cloud?** Unanswerable. The only
      trace was a hostname interpolated into the working copy's free-text label
      by `CmsHarness.Config.label/1`, which `CMS_HARNESS_LABEL` overrides and
      nothing parses.
    * **Are these two copies the same checkout?** Two rows can share a root, and
      root alone cannot be the key precisely because two machines can have the
      same path — the argument that made the server issue ids in the first
      place. Without a machine there is nothing to disambiguate with.
    * **This box is gone; is any of its state still claimed?** Copies expire one
      at a time, independently, with nothing tying them together.
    * **What is on my Mac mini?** The list is 105 rows with no grouping.

  ## Why the server issues the id

  The same reasoning as `harnesses`, one level up, and every client-derived
  alternative fails the same way: a hostname is generated for exactly the
  containers that collide, a MAC address is not stable across a re-image, and a
  path is not identity. So the daemon announces itself, is issued an id, and
  writes it to `~/.codemyspec/device.json` — beside the per-checkout
  `.cms_harness.json`, and for the same reason.

  ## `kind` is recorded, not derived

  A laptop authenticates with OAuth; a sprite has a deploy key and a pinned
  `:project_id`. The device already knows which it is at connect time
  (`HarnessProxySocket.socket_credential/0` picks between them), and that answer
  is thrown away on every request today. Recording it is cheaper and more honest
  than re-deriving it from a hostname that was never meant to carry it.

  `device_id` is nullable, and stays that way. A copy onboarded before this has
  no device and will not get one until its daemon reconnects and says so —
  which is a real state, not a defect, and different from a copy whose device is
  known.
  """

  use Ecto.Migration

  def change do
    create table(:devices, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # What the machine calls itself. Display only, and explicitly not
      # identity — generated container hostnames are why the id is issued.
      add :hostname, :text

      # What a person calls it. Null until somebody names it, so the UI can
      # fall back to the hostname rather than showing an empty string.
      add :label, :text

      # `local` (someone's machine, OAuth) or `cloud` (a provisioned sprite with
      # a deploy key). No default: an unknown kind should read as unknown rather
      # than quietly claiming to be a laptop.
      add :kind, :string

      add :account_id, :binary_id, null: false

      # The device's own liveness, distinct from any one copy's. A machine that
      # has gone takes every copy on it, and this is what says so.
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create index(:devices, [:account_id])

    alter table(:working_copies) do
      add :device_id, references(:devices, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:working_copies, [:device_id])
  end
end
