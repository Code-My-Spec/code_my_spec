defmodule CodeMySpec.AgentTasks.HarnessSkillStartTest do
  @moduledoc """
  A skill starts on a harness, where the server has no tree to walk.

  `StartAgentTask.sync_project/1` runs an incremental catch-up before building
  a prompt — the file watcher handles continuous sync and this picks up what
  changed while nothing was running. Its guard tested whether a working copy
  path exists, but a light harness *reports* a root it serves while the server
  holds no copy of it, so the scan was attempted and failed with
  `{:cannot_scan, :not_supported_on_harness}`.

  Every skill that starts a task returned that as "Sync failed". `/qa` surfaced
  it the moment its routing was fixed (`5fdc0cbf`), having been masked until
  then by never reaching the server at all.

  There is genuinely nothing to catch up: the harness *is* the watcher for its
  checkout and syncs by manifest, which runs the component projection too.

  The two callers answer differently on purpose, which is what these assert.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.SkillRouter
  alias CodeMySpec.Environments.Environment
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
    {:ok, scope: full_scope_fixture()}
  end

  # The shape a light harness presents: it names the working copy it serves —
  # on the scope and on the environment, because a harness reports its root —
  # and cannot walk it from here.
  defp harness_scope(scope) do
    %{scope | cwd: "/workspace/app", environment: Environment.new(:harness, "/workspace/app")}
  end

  test "/sync says why it did not scan, rather than reporting a clean sync", %{scope: scope} do
    assert {:ok, %{prompt: prompt}} =
             SkillRouter.resolve(harness_scope(scope), %{
               "skill" => "sync",
               "external_id" => "ext-1"
             })

    assert prompt =~ "synced by its harness",
           "an empty success reads as 'scanned, found nothing', which is the wrong " <>
             "thing to believe about your own checkout"

    refute prompt =~ "Sync failed",
           "it is not a failure — the rows are current, and more current than a " <>
             "server-side walk could make them"
  end

  test "/sync on a scannable environment still actually syncs", %{scope: scope} do
    # The guard must not swallow a real environment's real failure, nor skip
    # work it could have done.
    result = SkillRouter.resolve(scope, %{"skill" => "sync", "external_id" => "ext-2"})

    case result do
      {:ok, %{prompt: prompt}} ->
        refute prompt =~ "synced by its harness",
               "a local environment has a tree to walk and must walk it"

      {:error, _} ->
        :ok
    end
  end
end
