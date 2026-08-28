defmodule CodeMySpec.McpServers.Devops.Tools.ReadDatabaseUrlTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.Devops.Tools.ReadDatabaseUrl
  alias CodeMySpec.Provisioning.Database
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  setup do
    scope = full_scope_fixture()
    %{scope: scope, project: scope.active_project}
  end

  describe "execute/2" do
    # The whole point: :server already minted and stored this credential in
    # ProjectSecrets before it ever reaches the local-filesystem write that a
    # project with no checkout on this side cannot complete — this reads the
    # value back rather than minting a second one nobody asked for.
    test "returns the connection string :server already minted", %{scope: scope} do
      {:ok, credential} = Database.credential(scope, "prod")

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{environment: "prod"}

      assert {:reply, response, ^frame} = ReadDatabaseUrl.execute(params, frame)

      assert response.isError == false
      assert response_text(response) == Database.url(credential)
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
