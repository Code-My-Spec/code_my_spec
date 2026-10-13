defmodule CodeMySpec.Repo.Migrations.ACriterionCarriesItsOwnLatch do
  @moduledoc """
  Story 983's criteria 1895-1906: the specs-ready latch moves one level
  down, from the whole story to each criterion. `latched_at` is this
  criterion's own counterpart to `stories.specs_ready_at`
  (`20260917050000`) — set directly by whatever certifies it, read by
  nothing here yet. The story's own aggregate (criterion 1905) and the
  stop hook's per-criterion check (1898-1901) are separate work.
  """
  use Ecto.Migration

  def change do
    alter table(:criteria) do
      add :latched_at, :utc_datetime_usec
    end
  end
end
