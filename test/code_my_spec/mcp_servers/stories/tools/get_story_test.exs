defmodule CodeMySpec.McpServers.Stories.Tools.GetStoryTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Stories.Tools.GetStory
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "GetStory tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      params = %{story_id: story.id}

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetStory.execute(params, frame)
      assert response.type == :tool
    end

    test "returns not found error for non-existent story" do
      scope = full_scope_fixture()
      params = %{story_id: "99999"}

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetStory.execute(params, frame)
      assert response.type == :tool
      assert response.isError == true

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]
      assert content =~ "not found"
    end
  end
end
