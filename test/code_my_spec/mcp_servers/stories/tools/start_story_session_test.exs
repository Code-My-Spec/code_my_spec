defmodule CodeMySpec.McpServers.Stories.Tools.StartStorySessionTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Stories.Tools.StartStorySession
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

  describe "StartStorySession tool" do
    test "interview mode returns PM interview prompt" do
      scope = full_scope_fixture()
      _story = story_fixture(scope, %{title: "Test Story"})
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{mode: "interview"}
      assert {:reply, response, ^frame} = StartStorySession.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "Product Manager"
      assert text =~ "produce a set of bare user stories"
      assert text =~ "Test Story"
    end

    test "review mode returns PM review prompt" do
      scope = full_scope_fixture()
      _story = story_fixture(scope, %{title: "Review Story"})
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{mode: "review"}
      assert {:reply, response, ^frame} = StartStorySession.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "Product Manager"
      assert text =~ "story-level review"
      assert text =~ "Review Story"
    end

    test "returns error for invalid mode" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{mode: "invalid"}
      assert {:reply, response, ^frame} = StartStorySession.execute(params, frame)
      assert response.isError == true

      text = get_text(response)
      assert text =~ "Invalid mode"
    end

    test "handles empty project" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{mode: "interview"}
      assert {:reply, response, ^frame} = StartStorySession.execute(params, frame)
      assert response.type == :tool
      assert response.isError == false

      text = get_text(response)
      assert text =~ "No stories currently exist"
    end
  end
end
