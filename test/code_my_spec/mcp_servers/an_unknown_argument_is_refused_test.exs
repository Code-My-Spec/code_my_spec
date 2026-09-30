defmodule CodeMySpec.McpServers.AnUnknownArgumentIsRefusedTest do
  @moduledoc """
  87a3b848: `list_issues({ search = "sops" })` returned every issue, because
  the unknown argument was dropped rather than refused.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  setup do
    scope = full_scope_fixture()
    %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  defp run(frame, script) do
    {:reply, response, _frame} = RunScript.execute(%{script: script}, frame)

    {response.isError,
     response |> Response.to_protocol() |> Map.get("content") |> hd() |> Map.get("text")}
  end

  test "an argument the tool does not define stops the script, named", %{frame: frame} do
    assert {true, text} = run(frame, ~S[return list_issues({ search = "sops" })])

    assert text =~ "list_issues was called wrong and did not run"
    assert text =~ "unknown argument `search`"
    assert text =~ "valid arguments:"
    assert text =~ "`story_number`"
  end

  test "a known argument runs", %{frame: frame} do
    assert {false, _text} = run(frame, ~S[return list_issues({ status = "incoming" })])
  end

  test "a story alias counts as known", %{scope: scope, frame: frame} do
    story = story_fixture(scope, %{title: "Reached by story_id"})

    assert {false, text} = run(frame, ~s[return get_story({ story_id = #{story.number} })])
    assert text =~ "Reached by story_id"
  end
end
