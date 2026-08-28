defmodule CodeMySpec.McpServers.Devops.Tools.SetDevopsLevelTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.McpServers.Devops.Tools.SetDevopsLevel
  alias CodeMySpec.Resources
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  setup do
    scope = full_scope_fixture()
    %{scope: scope, project: scope.active_project}
  end

  describe "execute/2" do
    # The whole point: a project provisioned via run_provisioning_step
    # (rather than through the web UI's "Start setup", which flips this as a
    # side effect) defaults to :off forever, and devops_status silently
    # skips every :off project — not reporting it as missing, just never
    # asking about it. Confirmed live: MarketMySpec's devops_status reported
    # on an entirely different project in the account for this exact reason.
    test "marks the project devops-managed so devops_status stops skipping it", %{
      scope: scope,
      project: project
    } do
      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{project_id: project.id, level: "prod"}

      assert {:reply, response, ^frame} = SetDevopsLevel.execute(params, frame)

      assert response.isError == false
      assert response_text(response) =~ "prod"

      project_scope = Resources.project_scope(scope, project)
      assert %{devops: :prod} = Configurations.get(project_scope)
    end

    test "refuses an unknown level rather than guessing one", %{scope: scope, project: project} do
      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{project_id: project.id, level: "staging"}

      assert {:reply, response, ^frame} = SetDevopsLevel.execute(params, frame)
      assert response.isError == true
      assert response_text(response) =~ "unknown level"
    end

    test "refuses for a project that is not on this account", %{scope: scope} do
      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{project_id: "00000000-0000-0000-0000-000000000000", level: "prod"}

      assert {:reply, response, ^frame} = SetDevopsLevel.execute(params, frame)
      assert response.isError == true
      assert response_text(response) =~ "no project"
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
