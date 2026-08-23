defmodule CodeMySpec.Repo.Migrations.AProjectNamesTheCopyItIsReadFrom do
  use Ecto.Migration

  @moduledoc """
  Which checkout answers "what is the state of this project".

  Requirement satisfaction became per working copy in `20260824050000`, because
  that is what it has always been — a statement about what one checkout could
  see. That leaves the reader without a vantage point: an agent asks as its own
  copy, but the UI is not a copy and has to be told which one to speak for.

  Blending every copy was the alternative and it is the failure `Preloader`'s
  moduledoc already records one layer down: 308 (component, role) pairs
  satisfied by files that existed only in another checkout, 303 of them specs,
  so agents skipped work that had never been done. A union of checkouts
  describes a tree that never existed.

  So the project names one. In practice that is the main checkout — the one
  sitting there being pushed to while agents work in worktrees off it — which
  makes it the main-branch view without anything having to fetch main.

  ## Not `WorkingCopies.ensure_default/1`

  That is a nil object: its id is derived from the project id, nothing ever
  joins as it, `last_seen_at` is permanently nil and it therefore has no files.
  Reading requirements from it would answer false for everything. This has to
  point at a checkout that actually scans.

  ## nilify, not delete

  Offboarding the copy a project reads from must not take the project with it.
  The pointer goes null and the project falls back to having no canonical view —
  visible and fixable, which is the right failure for something an operator
  chose.
  """

  def change do
    alter table(:projects) do
      add :default_working_copy_id,
          references(:working_copies, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:projects, [:default_working_copy_id])
  end
end
