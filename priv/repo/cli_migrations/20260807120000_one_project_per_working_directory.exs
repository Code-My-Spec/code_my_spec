defmodule CodeMySpec.Repo.Migrations.OneProjectPerWorkingDirectory do
  use Ecto.Migration

  @moduledoc """
  A directory belongs to at most one project.

  `WorkingDirScope` resolves the working directory to a project by matching
  `local_path`, and every hook depends on that resolution. Nothing stopped two
  rows claiming the same path: the QA fixture's `local_path` was rewritten to
  the working checkout by a seed, the real project's was NULL, and for weeks
  every hook resolved to the fixture instead. It failed silently, which is the
  worst way for a load-bearing lookup to fail.

  Partial, because NULL means "this project has no checkout here" and any
  number of projects may be in that state.

  ## CLI only, deliberately

  This is not mirrored into `priv/repo/migrations`. `WorkingDirScope` lives in
  `CodeMySpecLocalWeb` — the cloud app has no working-directory plug and never
  resolves a project this way. The cloud database is multi-tenant, and two
  accounts landing on the same conventional path is ordinary rather than a
  collision: `/workspace/<app>` is the same string in every container. A global
  unique index there would refuse a legitimate pair, which is what
  `ProjectsTest` "ignores the working dir when a project is configured" exists
  to describe.

  So the invariant is real exactly where the lookup is: one local database, one
  developer, one directory per project.
  """

  def up do
    # A duplicate would make this migration fail on a database that already has
    # one, which is the right time to find out — but not the right way to learn
    # it. Named so the error says what is wrong.
    create unique_index(:projects, [:local_path],
             where: "local_path IS NOT NULL",
             name: :projects_one_per_local_path
           )
  end

  def down do
    drop index(:projects, [:local_path], name: :projects_one_per_local_path)
  end
end
