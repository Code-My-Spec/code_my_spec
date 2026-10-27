defmodule CodeMySpec.AgentTasks.QaSetupTest do
  @moduledoc false
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.QaSetup
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Qa.Documents

  defp create_scope(_context) do
    tmp_dir = CodeMySpec.TempFile.owned_dir("test")
    scope = working_copy_scope_fixture()
    env = ExecutionContext.new(:local, tmp_dir)
    scope = put_fixture_execution_context(scope, env)
    :ok = register_working_copy_execution_context(scope, env)

    %{
      scope: scope,
      task: %{project_id: scope.active_project.id, component_id: nil, story_id: nil}
    }
  end

  defp write_file!(scope, relative_path, content) do
    full_path = Path.join(fixture_execution_context(scope).cwd, relative_path)
    full_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(full_path, content)
  end

  defp valid_plan do
    """
    # QA Plan

    ## App Overview

    Phoenix app with session-based auth.

    ## Tools Registry

    Use the browser for LiveView pages.

    ## Seed Strategy

    Seed a QA account.
    """
  end

  describe "command/2" do
    setup :create_scope

    test "includes document instructions and required sections", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaSetup.command(scope, task)
      assert prompt =~ "write_document"
      assert prompt =~ "qa_plan"
      assert prompt =~ "App Overview"
      assert prompt =~ "Tools Registry"
      assert prompt =~ "Seed Strategy"
    end

    test "includes router content when a router exists", %{scope: scope, task: task} do
      write_file!(
        scope,
        "lib/my_app_web/router.ex",
        "defmodule MyAppWeb.Router do\n  live \"/dashboard\", DashboardLive\nend\n"
      )

      assert {:ok, prompt} = QaSetup.command(scope, task)
      assert prompt =~ "DashboardLive"
    end

    test "mentions an existing plan document", %{scope: scope, task: task} do
      assert {:ok, _} = Documents.put(scope, "qa_plan", nil, valid_plan())
      assert {:ok, prompt} = QaSetup.command(scope, task)
      assert prompt =~ ~r/existing plan/i
      assert prompt =~ "read_document"
    end

    test "offers route discovery when no router is found", %{scope: scope, task: task} do
      assert {:ok, prompt} = QaSetup.command(scope, task)
      assert prompt =~ "mix phx.routes"
    end
  end

  describe "evaluate/2" do
    setup :create_scope

    test "accepts a valid stored plan", %{scope: scope, task: task} do
      assert {:ok, _} = Documents.put(scope, "qa_plan", nil, valid_plan())
      assert {:ok, :valid} = QaSetup.evaluate(scope, task)
    end

    test "reports a missing plan document", %{scope: scope, task: task} do
      assert {:ok, :invalid, feedback} = QaSetup.evaluate(scope, task)
      assert feedback =~ "QA plan document not found"
      assert feedback =~ "write_document"
    end

    test "rejects a plan missing required sections without replacing the stored plan", %{
      scope: scope,
      task: task
    } do
      assert {:error, error} =
               Documents.put(scope, "qa_plan", nil, "# QA Plan\n\n## App Overview\n\nOverview.\n")

      assert error =~ "tools registry"
      assert error =~ "seed strategy"
      assert {:ok, :invalid, _feedback} = QaSetup.evaluate(scope, task)
    end

    test "validates journey plans against their own schema", %{scope: scope} do
      incomplete = "# QA Journey Plan\n\n## Journeys\n\n- Sign in.\n"
      assert {:error, error} = Documents.put(scope, "qa_journey_plan", nil, incomplete)
      assert error =~ "prerequisites"
      refute error =~ "tools registry"
    end
  end
end
