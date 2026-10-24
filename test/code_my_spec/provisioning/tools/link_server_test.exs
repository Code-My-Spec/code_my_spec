defmodule CodeMySpec.Provisioning.Tools.LinkServerTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.Servers

  setup do
    scope = full_scope_fixture()
    %{scope: scope, project: scope.active_project}
  end

  describe "execute/2" do
    test "points an environment at an already-linked account server", %{scope: scope} do
      {:ok, _} = CodeMySpec.Devices.link_provider_machine(scope, %{name: "fuellytics-prod"})
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{environment: "prod", server_name: "fuellytics-prod"}

      response =
        ToolLibrary.run(
          "link_server",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      assert response_text(response) =~ "prod now points at fuellytics-prod"

      environment = Environments.get(scope, "prod")
      linked = Servers.get_linked(scope, "fuellytics-prod")
      assert environment.device_id == linked.id
    end

    test "refuses when the server has not been linked to this account yet", %{scope: scope} do
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{environment: "prod", server_name: "not-linked-yet"}

      response =
        ToolLibrary.run(
          "link_server",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "not linked to this account"

      assert Environments.get(scope, "prod") == nil
    end
  end

  defp response_text({_status, text}), do: text
end
