defmodule CodeMySpec.Repo.Migrations.OneCheckoutPerDirectoryPerMachine do
  @moduledoc """
  One row per directory per machine, enforced by the database.

  `WorkingCopies.recognise_or_create/3` already looks a checkout up by
  `(project_id, device_id, root)` before minting, and that lookup is the only
  thing standing between one worktree and fifty rows describing it — measured
  on this project: 52 rows for one directory, five minted inside a single
  second, one of them carrying any files. Everything keyed on the working copy
  then splits across identities for the same place.

  A lookup is a rule the code remembers to follow. This is the same rule where
  it cannot be forgotten, and it turns the next regression from a slow drift
  into a refusal at the moment it happens.

  ## Nulls stay distinct, deliberately

  `NULLS NOT DISTINCT` is available here (Postgres 15.18) and is the wrong
  choice. It would make two device-less joins at one root collide — and minting
  two rows there is a decision with a test on it: without a device this cannot
  tell two machines apart, and merging on root alone folds somebody else's
  checkout into yours. Every container sits at `/workspace/app`.

  So the index mirrors the lookup exactly, including where the lookup declines
  to act. A row with no device, or no root, is the state "we have not been
  told", and two of those are not evidence of a duplicate.

  The cost is honest: this does not catch the historical pre-device duplicates,
  because those are the rows with nothing to compare. It guards the path every
  modern harness takes, where the device is known and the lookup is what stops
  the drift.

  Verified before writing: no row on this database violates this key.
  """
  use Ecto.Migration

  def change do
    create unique_index(
             :working_copies,
             [:project_id, :device_id, :root],
             name: :working_copies_project_device_root_index
           )
  end
end
