defmodule CodeMySpec.McpServers.Stories.Tools.StartStoryReviewTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Stories.Tools.StartStoryReview
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  defp get_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end

  describe "StartStoryReview tool" do
    test "returns the PM review prompt" do
      scope = full_scope_fixture()
      _story = story_fixture(scope, %{title: "Review Story"})
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = StartStoryReview.execute(%{}, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "Product Manager"
      assert text =~ "story-level review"
      assert text =~ "Review Story"
    end

    test "handles empty project" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = StartStoryReview.execute(%{}, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "No stories currently exist"
    end
  end
end
