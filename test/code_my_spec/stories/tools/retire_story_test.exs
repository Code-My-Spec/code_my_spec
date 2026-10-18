defmodule CodeMySpec.Stories.Tools.RetireStoryTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
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

      response =
        ToolLibrary.run(
          "retire_story",
          params,
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)
      assert CodeMySpec.Stories.get_story(scope, story.id).retired_at
    end
  end
end
