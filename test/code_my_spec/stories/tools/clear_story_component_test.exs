defmodule CodeMySpec.Stories.Tools.ClearStoryComponentTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "clears component from a linked story" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      story = story_fixture(scope, %{component_id: component.id})
      frame = %Frame{assigns: %{current_scope: scope}}

      assert story.component_id == component.id

      response =
        ToolLibrary.run(
          "clear_story_component",
          %{story_number: story.number},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      content = response_text(response)
      assert content =~ "cleared" or content =~ "unlinked" or content =~ story.title
    end

    test "handles already-unlinked story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      frame = %Frame{assigns: %{current_scope: scope}}

      assert is_nil(story.component_id)

      response =
        ToolLibrary.run(
          "clear_story_component",
          %{story_number: story.number},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
    end

    test "returns error for non-existent story" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "clear_story_component",
          %{story_number: 99_999},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "not found"
    end

    test "returns error without valid scope" do
      frame = %Frame{assigns: %{}}

      response =
        ToolLibrary.run(
          "clear_story_component",
          %{story_id: 1},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
    end
  end

  defp response_text({_status, text}), do: text
end
