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
    {:ok, env} = CodeMySpec.Environments.create(:memory, working_dir: "/memfs/pb-#{System.unique_integer([:positive])}")
    on_exit(fn -> CodeMySpec.Environments.destroy(env) end)
    %{scope: %{scope | environment: env}, env: env}
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

  test "a context writes both halves, and both are recognised", %{scope: scope, env: env} do
    project =
      ProjectBuilder.new(env, app: "my_app")
      |> ProjectBuilder.context("Accounts")
      |> ProjectBuilder.write!()

    paths = synced_paths(scope)

    assert ".code_my_spec/spec/my_app/accounts.spec.md" in paths,
           "The spec did not sync. Check it lands under Paths.spec_dir() and ends in .spec.md."

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

  test "spec_only and impl_only produce genuinely different halves", %{scope: scope, env: env} do
    ProjectBuilder.new(env, app: "my_app")
    |> ProjectBuilder.spec_only("Billing")
    |> ProjectBuilder.impl_only("Shipping")
    |> ProjectBuilder.write!()

    paths = synced_paths(scope)

    assert ".code_my_spec/spec/my_app/billing.spec.md" in paths
    refute "lib/my_app/billing.ex" in paths

    assert "lib/my_app/shipping.ex" in paths
    refute ".code_my_spec/spec/shipping.spec.md" in paths
  end

  test "nothing is written until write!/1", %{scope: scope, env: env} do
    ProjectBuilder.new(env, app: "my_app") |> ProjectBuilder.context("Accounts")

    assert synced_paths(scope) == MapSet.new(),
           "Composing wrote to the environment. The builder is meant to defer until write!/1 so a spec can land a project as one event rather than a trickle the graph debounces unpredictably."
  end
end
