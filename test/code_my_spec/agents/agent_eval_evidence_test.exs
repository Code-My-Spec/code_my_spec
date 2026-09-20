defmodule CodeMySpecSpex.AgentEvalEvidenceTest do
  use ExUnit.Case, async: true

  alias CodeMySpecSpex.AgentEvalHelpers

  @issue "11111111-1111-4111-8111-111111111111"

  test "correlates direct creation calls with their receipts" do
    transcript = """
      [agent] called create_issue(title: "Failure") id=call-1
      [agent] tool returned id=call-1
    Issue created: "Failure" [high] (ID: #{@issue})
    """

    assert AgentEvalHelpers.created_issue_ids(transcript) == [@issue]
  end

  test "accepts a script creation receipt without counting a prose claim" do
    transcript = """
      [agent] assistant: I called create_issue and created #{@issue}.
      [agent] called run_script(script: "return create_issue({title='Failure'})") id=call-2
      [agent] tool returned id=call-2
    Returned:
    Issue created: "Failure" [high] (ID: #{@issue})
    """

    assert AgentEvalHelpers.created_issue_ids(transcript) == [@issue]

    assert AgentEvalHelpers.created_issue_ids(
             "  [agent] assistant: Issue created: (ID: #{@issue})"
           ) == []
  end

  test "rejects uncorrelated, failed and listing receipts" do
    transcript = """
      [agent] called create_issue(title: "Failure") id=call-1
      [agent] tool returned id=other-call
    Issue created: "Failure" [high] (ID: #{@issue})
      [agent] tool failed id=call-1
    Issue created: "Failure" [high] (ID: #{@issue})
      [agent] called list_issues() id=call-3
      [agent] tool returned id=call-3
    Issue created: "Failure" [high] (ID: #{@issue})
    """

    assert AgentEvalHelpers.created_issue_ids(transcript) == []
  end

  test "a script merely reading an existing issue is not a creation call" do
    transcript = """
      [agent] called run_script(script: "return get_issue({issue_id='#{@issue}'})") id=read
      [agent] tool returned id=read
    Issue created: "Failure" [high] (ID: #{@issue})
    """

    assert AgentEvalHelpers.created_issue_ids(transcript) == []
  end
end
