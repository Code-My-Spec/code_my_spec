defmodule CodeMySpec.Repo.Migrations.AProjectHasAMainWorkingCopy do
  @moduledoc """
  One checkout per project is the one the project's own agent runs in.

  Designated, never inferred. The case that settles it already exists on this
  project: six checkouts of one repository, several of them worktrees of each
  other, one of them the place the work actually belongs. Nothing about a path,
  a label or a last-seen time picks the right one, and every rule that tries
  picks a different one as soon as somebody makes a second worktree.

  ## Why not `projects.default_working_copy_id`

  It is already taken, by something else that only looks similar.
  `WorkingCopies.ensure_default/1` mints a derived, rootless row per project so
  that writers with no checkout — a mix task, the web UI, a fixture — have
  somewhere to point. That row never joins, has no disk, and is deliberately
  distinguishable from a real checkout by having no `last_seen_at`.

  Reusing it would mean every one of those writers silently started pointing at
  a real checkout, and the nil-object would have no home. So this is its own
  fact, on the row it is a fact about.

  ## One, enforced

  A partial unique index rather than a column on `projects`: the flag belongs to
  the copy, and "at most one per project" is the constraint that makes reading
  it unambiguous. Postgres allows many rows where `main` is false, and exactly
  one where it is true.
  """
  use Ecto.Migration

  def change do
    alter table(:working_copies) do
      add :main, :boolean, null: false, default: false
    end

    create unique_index(:working_copies, [:project_id],
             where: "main",
             name: :working_copies_one_main_per_project_index
           )
  end
end
