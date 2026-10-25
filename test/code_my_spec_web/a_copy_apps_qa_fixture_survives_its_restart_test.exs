defmodule CodeMySpecWeb.ACopyAppsQaFixtureSurvivesItsRestartTest do
  @moduledoc """
  A copy's own app restarted keeps the QA fixtures `/dev/qa-agents` recorded:
  the copies are rows, and their local environments are registered again as
  the app starts. They were only in memory, so after a `restart_app` every
  analysis run there failed with `:no_environment` until QA set them up again.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.QaEnvironments
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    scope = full_scope_fixture()
    device = device_fixture(scope)

    %{
      root: root,
      qa: copy(scope, device, root, QaEnvironments.label()),
      other: copy(scope, device, root, "feature")
    }
  end

  # As `/dev/qa-agents` records one.
  defp copy(scope, device, root, label) do
    {:ok, copy} = WorkingCopies.issue(scope, nil, device: device.id, root: root, label: label)
    {:ok, copy} = WorkingCopies.report_root(copy, root)
    copy
  end

  test "the app's QA copies run locally again once it is back", ctx do
    start_supervised!({QaEnvironments, root: ctx.root})

    assert %{type: :local} = ExecutionContexts.lookup_registered({:working_copy, ctx.qa.id})
    assert is_nil(ExecutionContexts.lookup_registered({:working_copy, ctx.other.id}))
  end
end
