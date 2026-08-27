defmodule CodeMySpec.McpServers.Devops.Tools.LinkServerTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.Devops.Tools.LinkServer
  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias CodeMySpec.Servers.Server
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  setup do
    scope = full_scope_fixture()
    %{scope: scope, project: scope.active_project}
  end

  describe "execute/2" do
    test "points an environment at an already-linked account server", %{scope: scope, project: project} do
      {:ok, _} = Server.link(scope, %{name: "fuellytics-prod"})
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{project_id: project.id, environment: "prod", server_name: "fuellytics-prod"}
      assert {:reply, response, ^frame} = LinkServer.execute(params, frame)

      assert response.isError == false
      assert response_text(response) =~ "prod now points at fuellytics-prod"

      environment = EnvironmentRepository.get(scope, "prod")
      linked = Server.get_linked(scope, "fuellytics-prod")
      assert environment.server_id == linked.id
    end

    test "refuses when the server has not been linked to this account yet", %{
      scope: scope,
      project: project
    } do
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{project_id: project.id, environment: "prod", server_name: "not-linked-yet"}
      assert {:reply, response, ^frame} = LinkServer.execute(params, frame)

      assert response.isError == true
      assert response_text(response) =~ "not linked to this account"

      assert EnvironmentRepository.get(scope, "prod") == nil
    end

    test "refuses for a project that is not on this account", %{scope: scope} do
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{project_id: "00000000-0000-0000-0000-000000000000", environment: "prod", server_name: "x"}
      assert {:reply, response, ^frame} = LinkServer.execute(params, frame)

      assert response.isError == true
      assert response_text(response) =~ "no project"
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
