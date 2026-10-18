defmodule CodeMySpec.Stories.Tools.StoryTagToolsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpec.Tags
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  defp get_text({_status, text}), do: text

  describe "ListProjectTags tool" do
    test "lists all tags in the project" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      # Create some tags using Tags context directly
      Tags.add_tag(scope, story, "alpha")
      Tags.add_tag(scope, story, "beta")

      response =
        ToolLibrary.run(
          "list_project_tags",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      text = get_text(response)
      assert text =~ "alpha"
      assert text =~ "beta"
    end

    test "returns empty message when no tags exist" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "list_project_tags",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      text = get_text(response)
      assert text =~ "No tags found"
    end
  end

  describe "TagStories tool" do
    test "tags multiple stories at once" do
      scope = full_scope_fixture()
      story1 = story_fixture(scope, %{title: "Bulk 1"})
      story2 = story_fixture(scope, %{title: "Bulk 2"})
      story3 = story_fixture(scope, %{title: "Bulk 3"})
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{
        story_numbers: [story1.number, story2.number, story3.number],
        tag: "bulk-tag"
      }

      response =
        ToolLibrary.run(
          "tag_stories",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      text = get_text(response)
      assert text =~ "Tagged 3 stories"
    end

    test "reports failures for non-existent stories" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{
        story_numbers: [story.number, 99_999, 88_888],
        tag: "partial-tag"
      }

      response =
        ToolLibrary.run(
          "tag_stories",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      text = get_text(response)
      assert text =~ "Tagged 1 stories"
      assert text =~ "Not found"
    end
  end
end
