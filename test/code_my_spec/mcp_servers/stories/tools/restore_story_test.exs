defmodule CodeMySpec.McpServers.Stories.Tools.RestoreStoryTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.RestoreStory
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias Ecto.Adapters.SQL.Sandbox
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "RestoreStory tool" do
    test "restores a retired story with the criteria retired alongside it" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})

      {:ok, earlier} =
        AcceptanceCriteria.create_criterion(scope, story, %{description: "Retired before"})

      {:ok, _} = AcceptanceCriteria.retire_criterion(scope, earlier)

      {:ok, kept} =
        AcceptanceCriteria.create_criterion(scope, story, %{description: "Retired with it"})

      {:ok, _} = Stories.retire_story(scope, Stories.get_story(scope, story.id))

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               RestoreStory.execute(%{story_number: story.number}, frame)

      refute response.isError

      restored = Stories.get_story(scope, story.id)
      assert is_nil(restored.retired_at)
      refute restored.ready_for_dev
      assert Enum.map(restored.criteria, & &1.id) == [kept.id]
      assert AcceptanceCriteria.get_criterion(scope, earlier.id).retired_at
    end

    test "refuses a story that is not retired" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               RestoreStory.execute(%{story_number: story.number}, frame)

      assert response.isError
    end
  end
end
