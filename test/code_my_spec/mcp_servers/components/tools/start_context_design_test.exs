defmodule CodeMySpec.McpServers.Components.Tools.StartContextDesignTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.StartContextDesign
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "StartContextDesign tool" do
    test "executes and returns prompt response with valid scope" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = StartContextDesign.execute(%{}, frame)
      assert response.type == :tool
      assert response.isError == false
      assert [%{"text" => content_text, "type" => "text"}] = response.content
      assert is_binary(content_text)
      assert String.contains?(content_text, "expert Elixir architect")
    end
  end
end
