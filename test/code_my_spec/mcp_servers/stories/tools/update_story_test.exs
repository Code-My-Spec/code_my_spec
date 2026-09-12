defmodule CodeMySpec.McpServers.Stories.Tools.UpdateStoryTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory
  alias CodeMySpec.Tags
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "UpdateStory tool" do
    test "executes with valid params and scope" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      params = %{
        story_id: story.id,
        title: "Updated User Login",
        description: "Updated description"
      }

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = UpdateStory.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end

    test "can set tags on a story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{
        story_id: story.id,
        tags: ["accounts", "notifications"]
      }

      assert {:reply, response, ^frame} = UpdateStory.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false
    end

    test "can replace tags on a story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      # Add initial tags
      Tags.add_tag(scope, story, "old-tag")
      Tags.add_tag(scope, story, "keep-tag")

      # Replace with new set
      params = %{
        story_id: story.id,
        tags: ["keep-tag", "new-tag"]
      }

      assert {:reply, response, ^frame} = UpdateStory.execute(params, frame)
      assert response.isError == false
    end

    test "can clear all tags from a story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      # Add initial tags
      Tags.add_tag(scope, story, "tag-a")
      Tags.add_tag(scope, story, "tag-b")

      # Clear all tags
      params = %{
        story_id: story.id,
        tags: []
      }

      assert {:reply, response, ^frame} = UpdateStory.execute(params, frame)
      assert response.isError == false
    end
  end

  describe "epic_id" do
    # Asserted on `input_schema/0`, not by calling `execute/2`.
    #
    # The defect lives in the schema, not the handler: `transform_params/2`
    # already passes everything but story_id and acceptance_criteria through,
    # and `Story.changeset/2` casts `:epic_id`. What was missing was the field
    # declaration — and Anubis drops an undeclared parameter when it parses a
    # real MCP request, so the caller got a success and no change.
    #
    # A test that calls `execute/2` with an Elixir map cannot see any of that:
    # it bypasses the schema entirely and passes whether or not the field is
    # declared. I wrote that test first and it passed with the field removed,
    # which is the only reason this one exists.
    test "is declared, so a real MCP call is not silently stripped of it" do
      properties = UpdateStory.input_schema()["properties"]

      assert Map.has_key?(properties, "epic_id"),
             """
             epic_id is not on the tool's schema, so Anubis will drop it from
             any real MCP request and update_story will report success having
             changed nothing.

             A refusal would be fine. A success that did not happen is not.
             """
    end

    test "and it actually reaches the story when passed" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, epic} =
        CodeMySpec.Epics.create_epic(scope, %{
          name: "an epic",
          slug: "an-epic",
          description: "what this epic is for"
        })

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               UpdateStory.execute(%{story_id: story.id, epic_id: epic.id}, frame)

      assert response.isError == false
      assert CodeMySpec.Stories.get_story(scope, story.id).epic_id == epic.id
    end
  end
end
