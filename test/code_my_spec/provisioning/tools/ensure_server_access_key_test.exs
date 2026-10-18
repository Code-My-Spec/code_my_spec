defmodule CodeMySpec.Provisioning.Tools.EnsureServerAccessKeyTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame

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

      response =
        ToolLibrary.run(
          "ensure_server_access_key",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      text = response_text(response)
      assert text =~ "ssh-ed25519"
      refute text =~ "PRIVATE KEY"
    end

    test "errors cleanly when no scope can be resolved" do
      frame = %Frame{assigns: %{current_scope: nil, working_dir: nil}}

      response =
        ToolLibrary.run(
          "ensure_server_access_key",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
    end
  end

  defp response_text({_status, text}), do: text
end
