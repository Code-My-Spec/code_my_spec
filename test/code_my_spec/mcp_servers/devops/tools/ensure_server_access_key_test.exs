defmodule CodeMySpec.McpServers.Devops.Tools.EnsureServerAccessKeyTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.Devops.Tools.EnsureServerAccessKey
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  setup do
    Application.put_env(:code_my_spec, CodeMySpec.Servers,
      access_key: fn _scope -> {:ok, [1]} end
    )

    on_exit(fn -> Application.delete_env(:code_my_spec, CodeMySpec.Servers) end)

    %{scope: full_scope_fixture()}
  end

  describe "execute/2" do
    test "returns the account's public key, never the private half", %{scope: scope} do
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = EnsureServerAccessKey.execute(%{}, frame)

      assert response.isError == false
      text = response_text(response)
      assert text =~ "ssh-ed25519"
      refute text =~ "PRIVATE KEY"
    end

    test "errors cleanly when no scope can be resolved" do
      frame = %Frame{assigns: %{current_scope: nil, working_dir: nil}}

      assert {:reply, response, ^frame} = EnsureServerAccessKey.execute(%{}, frame)
      assert response.isError == true
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
