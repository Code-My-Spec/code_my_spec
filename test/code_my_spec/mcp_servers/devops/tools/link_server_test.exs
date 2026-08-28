defmodule CodeMySpec.McpServers.Devops.Tools.LinkServerTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Devops.Tools.LinkServer
  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias CodeMySpec.Servers.Server

  setup do
    scope = full_scope_fixture()
    %{scope: scope, project: scope.active_project}
  end

  describe "execute/2" do
    test "points an environment at an already-linked account server", %{scope: scope} do
      {:ok, _} = Server.link(scope, %{name: "fuellytics-prod"})
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{environment: "prod", server_name: "fuellytics-prod"}
      assert {:reply, response, ^frame} = LinkServer.execute(params, frame)

      assert response.isError == false
      assert response_text(response) =~ "prod now points at fuellytics-prod"

      environment = EnvironmentRepository.get(scope, "prod")
      linked = Server.get_linked(scope, "fuellytics-prod")
      assert environment.server_id == linked.id
    end

    test "refuses when the server has not been linked to this account yet", %{scope: scope} do
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{environment: "prod", server_name: "not-linked-yet"}
      assert {:reply, response, ^frame} = LinkServer.execute(params, frame)

      assert response.isError == true
      assert response_text(response) =~ "not linked to this account"

      assert EnvironmentRepository.get(scope, "prod") == nil
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
