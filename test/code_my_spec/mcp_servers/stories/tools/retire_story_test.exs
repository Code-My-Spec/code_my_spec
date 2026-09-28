defmodule CodeMySpec.McpServers.Stories.Tools.RetireStoryTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.RetireStory
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "RetireStory tool" do
    test "retires the story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      params = %{story_number: story.number}

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = RetireStory.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
      assert CodeMySpec.Stories.get_story(scope, story.id).retired_at
    end
  end
end
