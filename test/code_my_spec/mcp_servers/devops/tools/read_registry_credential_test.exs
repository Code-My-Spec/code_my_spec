defmodule CodeMySpec.McpServers.Devops.Tools.ReadRegistryCredentialTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.Devops.Tools.ReadRegistryCredential
  alias CodeMySpec.Provisioning.Registry
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  setup do
    scope = full_scope_fixture()
    %{scope: scope, project: scope.active_project}
  end

  describe "execute/2" do
    # The whole point: :server already minted and stored this credential in
    # ProjectSecrets before it ever reaches the local-filesystem write a
    # project with no checkout on this side cannot complete — this reads the
    # real values back rather than a caller having to guess or re-derive them.
    test "returns the registry :server already provisioned for this project", %{
      scope: scope,
      project: project
    } do
      {:ok, image} = Registry.image(scope)
      {:ok, credential} = Registry.credential(scope)

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{project_id: project.id}

      assert {:reply, response, ^frame} = ReadRegistryCredential.execute(params, frame)

      assert response.isError == false
      text = response_text(response)
      assert text =~ "registry: #{Registry.default_host()}"
      assert text =~ "image: #{image}"
      assert text =~ "username: #{credential.username}"
      assert text =~ "password: #{credential.password}"
    end

    test "refuses for a project that is not on this account", %{scope: scope} do
      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{project_id: "00000000-0000-0000-0000-000000000000"}

      assert {:reply, response, ^frame} = ReadRegistryCredential.execute(params, frame)
      assert response.isError == true
      assert response_text(response) =~ "no project"
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
