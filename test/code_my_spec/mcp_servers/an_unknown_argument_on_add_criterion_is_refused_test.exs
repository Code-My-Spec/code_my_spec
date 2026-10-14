defmodule CodeMySpec.McpServers.AnUnknownArgumentOnAddCriterionIsRefusedTest do
  @moduledoc """
  Issue 89db761c: `add_criterion({ story_number = ..., description = "...", 
  body = "..." })` returned success seven times and stored nothing of the
  extra `body` -- the same unknown-argument class as 87a3b848
  (`AnUnknownArgumentIsRefusedTest`), on the specific tool this incident
  named.

  Already fixed generically by `CodeMySpec.McpServers.CodeMode.known/2`
  (commit 1e7a90fd1), verified here on `add_criterion` itself rather than
  assumed from the general mechanism.
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

  test "a body argument add_criterion does not declare stops the script, named", %{
    scope: scope,
    frame: frame
  } do
    story = story_fixture(scope, %{title: "Reservations user story"})

    script = ~s[
      return add_criterion({
        story_number = #{story.number},
        description = "a criterion",
        body = "Given...When...Then..."
      })
    ]

    assert {true, text} = run(frame, script)

    assert text =~ "add_criterion was called wrong and did not run"
    assert text =~ "unknown argument `body`"
    assert text =~ "valid arguments:"
    assert text =~ "`description`"
    assert text =~ "`story_number`"
  end

  test "only its declared arguments run, and store nothing of an unknown one", %{
    scope: scope,
    frame: frame
  } do
    story = story_fixture(scope, %{title: "Reservations user story"})

    script = ~s[
      return add_criterion({
        story_number = #{story.number},
        description = "a plain criterion"
      })
    ]

    assert {false, _text} = run(frame, script)
  end
end
