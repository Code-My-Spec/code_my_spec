defmodule CodeMySpec.McpServers.Stories.Tools.CreateStoriesTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Stories.Tools.CreateStories
  alias Anubis.Server.Frame
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "CreateStories tool" do
    test "executes with valid params and scope" do
      params = %{
        stories: [
          %{
            "title" => "User Login",
            "description" => "As a user I want to login",
            "acceptance_criteria" => [
              "User can enter credentials",
              "System validates credentials"
            ]
          },
          %{
            "title" => "User Logout",
            "description" => "As a user I want to logout",
            "acceptance_criteria" => ["User can click logout", "Session is terminated"]
          }
        ]
      }

      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}
      assert {:reply, response, ^frame} = CreateStories.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end
  end
end
