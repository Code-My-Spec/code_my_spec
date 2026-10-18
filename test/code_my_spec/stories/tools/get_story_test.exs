defmodule CodeMySpec.Stories.Tools.GetStoryTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
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
      params = %{story_number: story.number}

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:ok, _} =
               ToolLibrary.run(
                 "get_story",
                 params,
                 Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
               )
    end

    test "includes the epic name when the story belongs to one" do
      scope = full_scope_fixture()
      {:ok, epic} = CodeMySpec.Epics.create_epic(scope, %{name: "Billing Overhaul"})
      story = story_fixture(scope)
      {:ok, story} = CodeMySpec.Stories.update_story(scope, story, %{epic_id: epic.id})

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "get_story",
          %{story_number: story.number},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      {_, content} = response
      assert content =~ "**Epic:** Billing Overhaul"
    end

    test "omits the epic line when the story has no epic" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "get_story",
          %{story_number: story.number},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      {_, content} = response
      refute content =~ "**Epic:**"
    end

    test "returns not found error for non-existent story" do
      scope = full_scope_fixture()
      params = %{story_number: 99_999}

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "get_story",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)

      {_, content} = response
      assert content =~ "not found"
    end
  end
end
