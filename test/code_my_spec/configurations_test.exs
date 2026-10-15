defmodule CodeMySpec.ConfigurationsTest do
  @moduledoc """
  09fd73a4: get_or_create/1 used to raise Ecto.InvalidChangesetError when it
  lost a read-then-insert race against a concurrent caller for the same
  project (two processes both see no row, both try to insert, the loser
  hits unique_constraint(:project_id)). Reproduced directly under load
  running test/code_my_spec/requirements together with test/code_my_spec/agents,
  test/code_my_spec/main_agent and test/code_my_spec/analysis -- the raise
  was caught by IncrementalGraph.drain/1's own rescue clause, which swallowed
  it and left that project's graph exactly as stale as before the attempt.
  That is what let a satisfied requirement (ready_for_qa) keep being offered
  after its own recompute kept failing this way.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Configurations.ProjectConfiguration

  test "concurrent callers for a project with no configuration yet all succeed and agree on one row" do
    scope = full_scope_fixture()

    results =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> Configurations.get_or_create(scope) end) end)
      |> Task.await_many(5_000)

    ids = results |> Enum.map(& &1.id) |> Enum.uniq()
    assert [_single_id] = ids

    assert Repo.aggregate(
             from(c in ProjectConfiguration, where: c.project_id == ^scope.active_project_id),
             :count
           ) == 1
  end
end
