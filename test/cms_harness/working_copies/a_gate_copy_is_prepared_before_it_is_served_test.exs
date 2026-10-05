defmodule CmsHarness.WorkingCopies.AGateCopyIsPreparedBeforeItIsServedTest do
  @moduledoc """
  A copy made to be the promotion gate runs the project's `gate-setup` recipe
  before it is served — the first live batch's gate copy was minted without its
  envs and could not boot the test suite. While it is being prepared, or after
  the recipe failed, the harness does not serve it.

  The recipe's runner is passed in: what is under test is which answer marks
  the copy ready and which keeps it unserved, not that `just` runs.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Projects
  alias CmsHarness.WorkingCopies.Create

  setup do
    {:ok, root} = Briefly.create(directory: true)
    File.write!(Path.join(root, ".cms_harness_preparing"), "preparing\n")
    %{root: root}
  end

  defp answering(out, status) do
    test = self()

    fn recipe, dir ->
      send(test, {:ran, recipe, dir})
      {out, status}
    end
  end

  test "the project's gate-setup recipe runs in the copy, and the copy is ready", %{root: root} do
    assert :ok = Create.prepare(root, answering("Ready.\n", 0))
    assert_received {:ran, "gate-setup", ^root}
    refute Create.preparing?(root)
  end

  test "a recipe that fails leaves the copy unready, with why", %{root: root} do
    assert {:error, {:prepare_failed, 3}} =
             Create.prepare(root, answering("Environment variable GITHUB_CLIENT_ID not set", 3))

    assert Create.preparing?(root)
    assert File.read!(Path.join(root, ".cms_harness_preparing")) =~ "GITHUB_CLIENT_ID not set"
  end

  test "a project with no such recipe has nothing to run", %{root: root} do
    assert :ok =
             Create.prepare(
               root,
               answering("error: Justfile does not contain recipe `gate-setup`", 1)
             )

    refute Create.preparing?(root)
  end

  test "a copy being prepared is not served", %{root: root} do
    assert {:error, :preparing} = Projects.ensure_started(root)
  end
end
