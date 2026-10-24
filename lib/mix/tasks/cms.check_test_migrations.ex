defmodule Mix.Tasks.Cms.CheckTestMigrations do
  @shortdoc "Refuse to run against a test database this working copy has outgrown"

  @moduledoc """
  Answer whether this working copy's test database is behind its migrations.

      MIX_ENV=test mix cms.check_test_migrations

  A thin wrapper over `CodeMySpec.TestMigrations.refuse_if_behind!/0`, which
  holds the actual logic -- a `Mix.Tasks.*` module is only callable from
  outside its own boundary when it is also named under that boundary's own
  namespace, which this one is not, so the logic lives where it can
  actually be depended on.
  """

  use Mix.Task
  use Boundary, classify_to: CodeMySpec

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args), do: CodeMySpec.TestMigrations.refuse_if_behind!()
end
