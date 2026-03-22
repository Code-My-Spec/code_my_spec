defmodule CodeMySpec.McpServers.Stories.Tools.CreateStoryTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias Anubis.Server.Frame
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "CreateStory tool" do
    test "executes with valid params and scope" do
      params = %{
        title: "User Login",
        description: "As a user I want to login",
        acceptance_criteria: ["User can enter credentials", "System validates credentials"]
      }

      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = CreateStory.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end
  end
end
