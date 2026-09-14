defmodule CodeMySpec.Repo.Migrations.APromotionOriginatesAPermanentStoryVersion do
  @moduledoc """
  Adds `stories.promoted_version`.

  Nullable, no default: nil means "never promoted" (or "revoked, needs
  re-promotion" — the same nil a story's own graph invalidation sets to
  force it back through the gate). Once a promotion sets it, nothing about
  that checkout's later git state can change it back — the column is a
  permanent stamp, not a live read of the working copy the story happened
  to be promoted from.
  """

  use Ecto.Migration

  def change do
    alter table(:stories) do
      add :promoted_version, :string
    end
  end
end
