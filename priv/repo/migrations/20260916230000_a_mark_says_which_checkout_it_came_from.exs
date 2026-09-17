defmodule CodeMySpec.Repo.Migrations.AMarkSaysWhichCheckoutItCameFrom do
  @moduledoc """
  The vantage a mark was recorded from.

  A verdict is a statement about a checkout — `Preloader` scopes its files to
  one, so "this component has a spec" is only true from somewhere. The graph is
  therefore projected per vantage, and the pass recomputes each in turn.

  The marks carried no such thing, so a consumer could not tell a file sync in
  one worktree from a story edit that moves every checkout's answer. The only
  safe reading was "all of them", which is a loop over nine vantages for an
  event that moved one.

  `NULL` means project-wide, and is the honest answer for a writer whose change
  is not about a checkout — a story renamed, an issue accepted. It is the same
  shape `entity_scope` already uses for "this writer could not narrow": absent
  is the conservative reading, not a gap.

  No foreign key, for `20260916013000`'s reason — a delete broadcasts after its
  row is gone, and an FK here turns a projection write into a raise inside an
  unrelated domain write.
  """
  use Ecto.Migration

  def change do
    alter table(:graph_invalidations) do
      add :working_copy_id, :binary_id
    end

    create index(:graph_invalidations, [:project_id, :working_copy_id])
  end
end
