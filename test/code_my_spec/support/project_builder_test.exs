defmodule CodeMySpecSpex.ProjectBuilderTest do
  @moduledoc """
  The builder's only interesting claim is that the scanner *recognises* what it
  writes. Asserting the files exist proves nothing — `write_file/3` obviously
  writes files. An unclassified file never syncs, so a builder writing to paths
  nobody reads would produce a project that looks full and behaves empty, and
  every spec built on it would pass while testing nothing.

  So these tests sync, and assert against what came back.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias CodeMySpecSpex.ProjectBuilder

  setup do
    scope = CodeMySpec.UsersFixtures.full_scope_fixture()

    {:ok, env} =
      CodeMySpec.Environments.create(:memory,
        working_dir: "/memfs/pb-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> CodeMySpec.Environments.destroy(env) end)
    %{scope: put_fixture_environment(scope, env), env: env}
  end

  defp synced_paths(scope) do
    {:ok, _} = FileSync.sync(scope)
    scope |> Files.list_files() |> Enum.map(& &1.path) |> MapSet.new()
  end

  test "a new project's mix.exs is classified and synced", %{scope: scope, env: env} do
    ProjectBuilder.new(env, app: "my_app") |> ProjectBuilder.write!()

    paths = synced_paths(scope)

    assert "mix.exs" in paths,
           "mix.exs did not sync. Without it a tree reads as 'not a project' rather than an empty one."

    assert "lib/my_app.ex" in paths
  end

  test "a context writes its implementation, and it is recognised", %{scope: scope, env: env} do
    project =
      ProjectBuilder.new(env, app: "my_app")
      |> ProjectBuilder.context("Accounts")
      |> ProjectBuilder.write!()

    paths = synced_paths(scope)

    assert "lib/my_app/accounts.ex" in paths
    assert "MyApp.Accounts" in project.modules
  end

  test "every path the builder writes is one the scanner classifies", %{scope: scope, env: env} do
    written =
      ProjectBuilder.new(env, app: "my_app")
      |> ProjectBuilder.context("Accounts")
      |> ProjectBuilder.component("Accounts", "User")
      |> ProjectBuilder.unit_test("Accounts")
      |> ProjectBuilder.spex(1047, 7001)
      |> ProjectBuilder.write!()

    synced = synced_paths(scope)
    missing = Enum.reject(written.paths, &MapSet.member?(synced, &1))

    assert missing == [],
           """
           The builder wrote paths the scanner did not classify:

             #{Enum.join(missing, "\n  ")}

           An unclassified file never syncs, so a project built from these
           would look full and behave empty. Either the path convention moved
           or the builder is writing somewhere nobody reads.
           """
  end

  test "nothing is written until write!/1", %{scope: scope, env: env} do
    ProjectBuilder.new(env, app: "my_app") |> ProjectBuilder.context("Accounts")

    assert synced_paths(scope) == MapSet.new(),
           "Composing wrote to the environment. The builder is meant to defer until write!/1 so a spec can land a project as one event rather than a trickle the graph debounces unpredictably."
  end
end
