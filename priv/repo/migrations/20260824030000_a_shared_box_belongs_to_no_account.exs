defmodule CodeMySpec.Repo.Migrations.ASharedBoxBelongsToNoAccount do
  @moduledoc """
  A device may belong to no account.

  `account_id` was `null: false`, which quietly asserted that every machine is
  somebody's. A shared development box is not: several people work on it, it
  holds no project of its own, and forcing it to claim an account would attach
  it to whichever one happened to announce first.

  Nullable is the honest shape. "This machine belongs to nobody" and "we do not
  know whose this is" are the same row, and both are true of a shared box —
  the same reasoning that keeps `working_copies.device_id` nullable rather than
  inventing a machine for a checkout that never reported one.

  Devices stay account-*scoped* where an account exists. This widens what may be
  stored, not who may read it.
  """

  use Ecto.Migration

  def up do
    alter table(:devices) do
      modify :account_id, :binary_id, null: true, from: {:binary_id, null: false}
    end
  end

  def down do
    # Irreversible in general: a shared box has no account to put back, so
    # anything that announced without one would have to be invented or deleted.
    # Rolling back is a decision about that data, not a mechanical step.
    execute("DELETE FROM devices WHERE account_id IS NULL")

    alter table(:devices) do
      modify :account_id, :binary_id, null: false, from: {:binary_id, null: true}
    end
  end
end
