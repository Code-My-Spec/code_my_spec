defmodule CodeMySpec.Stories.Tools.StartStoryInterviewTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  defp get_text({_status, text}), do: text

  describe "StartStoryInterview tool" do
    test "returns the PM interview prompt" do
      scope = full_scope_fixture()
      _story = story_fixture(scope, %{title: "Test Story"})
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "start_story_interview",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      text = get_text(response)
      assert text =~ "Product Manager"
      assert text =~ ~r/produce a set of\s+bare user stories/
      assert text =~ "Test Story"
    end

    test "handles empty project" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "start_story_interview",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      text = get_text(response)
      assert text =~ "No stories currently exist"
    end
  end
end
