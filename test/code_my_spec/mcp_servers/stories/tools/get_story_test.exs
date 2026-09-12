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

    test "includes the epic name when the story belongs to one" do
      scope = full_scope_fixture()
      {:ok, epic} = CodeMySpec.Epics.create_epic(scope, %{name: "Billing Overhaul"})
      story = story_fixture(scope)
      {:ok, story} = CodeMySpec.Stories.update_story(scope, story, %{epic_id: epic.id})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetStory.execute(%{story_id: story.id}, frame)

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]
      assert content =~ "**Epic:** Billing Overhaul"
    end

    test "omits the epic line when the story has no epic" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetStory.execute(%{story_id: story.id}, frame)

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]
      refute content =~ "**Epic:**"
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
