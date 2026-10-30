defmodule CmsHarness.GitSnapshotSpawnRefusalTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Project.AnalysisServer
  alias CmsHarness.Sync
  alias CodeMySpec.ExecutionContexts.ExecutionContext

  setup do
    root = "git-snapshot-#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: Sync.task_supervisor(root)})
    %{env: ExecutionContext.new(:local, root)}
  end

  test "a git spawn refusal reports a failed snapshot without killing its analyzer owner", %{
    env: env
  } do
    spawn_error =
      {:eperm, [{:erlang, :open_port, [{:spawn_executable, "/opt/homebrew/bin/git"}, []]}]}

    assert {:error, reason} = AnalysisServer.snapshot_tree_state(env, fn -> exit(spawn_error) end)
    assert reason =~ ":eperm"
    assert reason =~ "/opt/homebrew/bin/git"
    assert Process.alive?(self())
  end

  test "a successful snapshot still supplies the tree", %{env: env} do
    tree = %{commit: String.duplicate("a", 40), dirty: false}
    assert {:ok, ^tree} = AnalysisServer.snapshot_tree_state(env, fn -> tree end)
  end
end
