defmodule CodeMySpec.McpServers.Stories.Tools.DeleteStoryTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Stories.Tools.DeleteStory
  alias Anubis.Server.Frame
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "DeleteStory tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      params = %{story_id: story.id}

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = DeleteStory.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end
  end
end
