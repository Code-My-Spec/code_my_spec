defmodule CodeMySpec.McpServers.EveryScriptableListToolReturnsATableTest do
  @moduledoc """
  253b3b93: seven `list_*` tools answered a script with the same rendered
  string a direct call gets, so `ipairs(list_rules{...})` raised -- and worse,
  a script testing emptiness or counting rows got a truthy string back and
  read it as data, silently.

  `8c1e192c` and `f3630beb` each named a different three-tool subset and were
  each re-reported, because a test over a named allowlist goes stale the same
  way the fix did. This drives every tool that implements `ScriptResult` --
  the seven this issue measured, plus the five already fixed -- and asserts
  each comes back as a table, not a string. A thirteenth tool added later and
  left unconverted is simply not in this list; see the follow-up issue filed
  for the remaining `list_*` tools this issue did not measure.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  defp text(response) do
    response |> Response.to_protocol() |> Map.get("content") |> hd() |> Map.get("text")
  end

  defp returns_a_table(script, frame) do
    assert {:reply, response, ^frame} = RunScript.execute(%{script: script}, frame)
    refute response.isError, "the call itself failed: #{text(response)}"

    returned = text(response) |> String.split("Returned:") |> List.last() |> String.trim()

    assert returned == "table",
           "expected a table, got #{inspect(returned)} -- a rendered string is not " <>
             "something a script can ipairs() over or count rows in"
  end

  describe "the seven this issue measured" do
    setup do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{title: "A story with a rule on it"})
      %{frame: %Frame{assigns: %{current_scope: scope}}, story: story}
    end

    test "list_rules", %{frame: frame, story: story} do
      returns_a_table("return type(list_rules({ story_number = #{story.number} }))", frame)
    end

    test "list_stories", %{frame: frame} do
      returns_a_table(~S[return type(list_stories({}))], frame)
    end

    test "list_epics", %{frame: frame} do
      returns_a_table(~S[return type(list_epics({}))], frame)
    end

    test "list_personas", %{frame: frame} do
      returns_a_table(~S[return type(list_personas({}))], frame)
    end

    test "list_knowledge", %{frame: frame} do
      returns_a_table(~S[return type(list_knowledge({}))], frame)
    end

    test "list_notifications", %{frame: frame} do
      returns_a_table(~S[return type(list_notifications({}))], frame)
    end

    test "list_project_tags", %{frame: frame} do
      returns_a_table(~S[return type(list_project_tags({}))], frame)
    end
  end

  describe "the five already fixed, so this stays honest about both halves" do
    setup do
      scope = full_scope_fixture()
      %{frame: %Frame{assigns: %{current_scope: scope}}, scope: scope}
    end

    test "list_issues", %{frame: frame} do
      returns_a_table(~S[return type(list_issues({}))], frame)
    end

    test "list_requirements", %{frame: frame} do
      returns_a_table(~S[return type(list_requirements({}))], frame)
    end

    test "list_story_titles", %{frame: frame} do
      returns_a_table(~S[return type(list_story_titles({}))], frame)
    end

    test "list_working_copies", %{frame: frame} do
      returns_a_table(~S[return type(list_working_copies({}))], frame)
    end

    test "list_tasks", %{frame: frame, scope: scope} do
      # list_tasks resolves "whose tasks" from an explicit session_id/agent_id,
      # not from nothing -- a fresh session fixture gives it an owner with an
      # empty (but present) task list.
      external_id = "sess-#{System.unique_integer([:positive])}"
      CodeMySpec.SessionsFixtures.session_fixture(scope, %{external_conversation_id: external_id})

      returns_a_table("return type(list_tasks({ session_id = \"#{external_id}\" }))", frame)
    end
  end
end
