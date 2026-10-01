defmodule CodeMySpec.Repo.Migrations.AProjectTracksItsOwnMixLockFingerprint do
  @moduledoc """
  577de9bb step 3: the dependency reconciler's trigger. `project_dependencies`
  is populated from `mix.lock`, but nothing records which version of the lock
  was last read — so there is no cheap way to tell "the main copy's mix.lock
  moved" from "it didn't," short of re-parsing and re-diffing it every time.

  This stamps the fingerprint `Files.Scanner` already computes for every
  synced file onto the project itself, the moment that lock is successfully
  read and recorded. No default: a project with nothing recorded yet has
  never had its lock reconciled, and that is `nil`, not an empty string.
  """

  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :mix_lock_fingerprint, :string
    end
  end
end
