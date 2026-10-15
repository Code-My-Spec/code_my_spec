defmodule CodeMySpec.McpServers.LibraryToolsTest do
  @moduledoc """
  A domain tool on LocalServer's direct list, through the requests a client
  sends: `init/2` registers it on the session's frame, `tools/list` advertises
  it, and `tools/call` runs it with Anubis's own argument validation.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpec.McpServers.ScriptableTools

  defp session(assigns) do
    {:ok, frame} = LocalServer.init(%{}, %Frame{assigns: assigns})
    frame
  end

  defp request(method, params),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp listed(frame) do
    {:reply, %{"tools" => tools}, _frame} =
      LocalServer.handle_request(request("tools/list", %{}), frame)

    tools
  end

  defp call(frame, arguments) do
    LocalServer.handle_request(
      request("tools/call", %{"name" => "reject_offer", "arguments" => arguments}),
      frame
    )
  end

  setup do
    %{scope: full_scope_fixture()}
  end

  test "a session lists the library tool with its schema", %{scope: scope} do
    tool = Enum.find(listed(session(%{current_scope: scope})), &(&1.name == "reject_offer"))

    assert tool, "reject_offer is not on the session's tool list"
    assert tool.input_schema["required"] == ["reason"]
    assert tool.description =~ "Decline an offer"
  end

  test "a call reaches the tool, which answers in its own words", %{scope: scope} do
    assert {:reply, %{"isError" => true, "content" => [%{"text" => text}]}, _frame} =
             call(session(%{current_scope: scope}), %{"reason" => "not mine"})

    assert text =~ "is for agents the harness offers work to"
  end

  test "a call missing a required argument is refused before the tool runs", %{scope: scope} do
    assert {:error, error, _frame} = call(session(%{current_scope: scope}), %{})
    assert inspect(error) =~ "reason"
  end

  test "the tool is direct, so scripts do not list it" do
    assert Enum.any?(LocalServer.registrations(), &(&1.name == "reject_offer"))
    refute Enum.any?(ScriptableTools.registrations(), &(&1.name == "reject_offer"))
  end
end
