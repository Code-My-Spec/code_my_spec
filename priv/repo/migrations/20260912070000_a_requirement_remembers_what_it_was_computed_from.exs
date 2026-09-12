defmodule CodeMySpec.Repo.Migrations.ARequirementRemembersWhatItWasComputedFrom do
  @moduledoc """
  Per-requirement input fingerprints, so freshness is a question about one
  requirement rather than about the whole project.

  Story 1020. The graph carries a single fingerprint hashed over every input a
  project has, so any observation busts all of it and the next read rebuilds
  every node and edge. Measured on this project with a handful of agents:
  348 full computes in one log, median 2.6s, p90 5.9s, max 14.8s, 116 of them
  triggered by stop hooks. Edges alone were 6489ms of a 10203ms compute.

  The cost is not the hash, it is the grain. A file appearing under one
  component says nothing about a story assigned to another checkout, and the
  fingerprint cannot express that — so it discards both.

  `inputs_fingerprint` is that grain: what this requirement's own sources
  looked like when its answer was last worked out. A read compares per row and
  recomputes the ones whose sources moved, which is the difference between work
  proportional to the change and work proportional to the project.

  Nullable, and deliberately. Every existing row predates this and has no
  honest value to backfill — a fingerprint invented for a row we did not
  compute would claim the row is current when nothing checked. `nil` reads as
  "no basis to skip this one", so the first pass after this migration
  recomputes as it does today and fills them in truthfully.
  """

  use Ecto.Migration

  def change do
    alter table(:requirements) do
      add :inputs_fingerprint, :string
    end

    # Read beside `working_copy_id`, because freshness is asked per checkout:
    # the same requirement has a different answer, and a different set of
    # inputs, in a tree that has the file and one that does not.
    create index(:requirements, [:working_copy_id, :inputs_fingerprint])
  end
end
