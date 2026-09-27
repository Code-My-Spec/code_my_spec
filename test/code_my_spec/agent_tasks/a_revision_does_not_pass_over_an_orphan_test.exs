defmodule CodeMySpec.AgentTasks.ARevisionDoesNotPassOverAnOrphanTest do
  @moduledoc """
  A revision passes only when the `architecture_designed` requirement would.

  It checked only for unlinked stories, so on metric_flow (2026-09-27) the task
  passed while `MetricFlowWeb.OnboardingLive` stayed an orphan: the requirement
  stayed unmet and every role was offered the same task again.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  alias CodeMySpec.AgentTasks.ArchitectureDesign
  alias CodeMySpec.Environments.Environment

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    scope = %{full_scope_fixture() | cwd: tmp, environment: Environment.new(:local, tmp)}

    # A component exists, so `command/2` records revision mode.
    orphan = component_fixture(scope, %{type: "context"})

    {_n, _} =
      CodeMySpec.Files.upsert_files(scope, [
        %{
          path: "lib/" <> Macro.underscore(orphan.module_name) <> ".ex",
          role: :implementation,
          component_id: orphan.id,
          valid: true,
          mtime: DateTime.utc_now()
        }
      ])

    {:ok, _prompt} = ArchitectureDesign.command(scope, %{id: 1})

    %{scope: scope, orphan: orphan}
  end

  test "an orphan context fails the evaluation and is named", %{scope: scope, orphan: orphan} do
    assert {:ok, :invalid, feedback} = ArchitectureDesign.evaluate(scope, %{id: 1})
    assert feedback =~ orphan.module_name
  end
end
