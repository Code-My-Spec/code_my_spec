defmodule CodeMySpec.Repo.Migrations.ALatchSaysWhenAndWhereItWasEarned do
  @moduledoc """
  `specs_ready` is a project-wide latch: once one checkout's spex go green for
  a story, every checkout is held to those findings — including ones that do
  not have the fix yet (`51e319db`). A live git-ancestry check to enforce that
  correctly would mean either blocking the stop hook's decision path on a
  harness round-trip (the opposite of what it was redesigned to do) or
  caching a checkout's git state on `working_copies` again, which
  `20260915220000_a_checkout_stops_mirroring_git.exs` just removed for
  measurably disagreeing with reality.

  So this does not gate anything. It only records the two facts a reader
  needs to tell "I broke this" from "this was already earned somewhere else":
  when the latch was set, and on which commit. Read-only, DB-only, on the
  exact same fast path every other blocking message already renders from —
  no new git call in the stop hook, ever. Whatever wrote the commit sha did
  its own one-time `git rev-parse HEAD`, at the moment the latch flipped, not
  on every later read of it.
  """
  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :specs_ready_at, :utc_datetime_usec
      add :specs_ready_commit, :string
    end
  end
end
