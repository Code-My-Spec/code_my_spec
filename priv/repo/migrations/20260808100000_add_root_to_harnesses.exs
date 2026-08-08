defmodule CodeMySpec.Repo.Migrations.AddRootToHarnesses do
  use Ecto.Migration

  @moduledoc """
  Where a harness says its working copy is.

  Reported data, not identity. Routing a hook used to start from the path the
  hook announced and walk up to the nearest `mix.exs`, which meant the same
  session resolved to different roots depending on the subdirectory it fired
  from, and two checkouts sharing a parent could resolve to each other. The
  path is now something a harness tells us about itself after it has already
  said who it is.

  Deliberately not unique. Two containers at `/workspace/app` on hosts with
  generated names report the same string and are still two harnesses — that
  collision is the reason identity is issued rather than derived, so a unique
  index here would reintroduce exactly what the id exists to avoid.

  Nullable: every harness issued before this column existed has no root to
  report until it reconnects and says so.
  """

  def change do
    alter table(:harnesses) do
      add :root, :text
    end
  end
end
