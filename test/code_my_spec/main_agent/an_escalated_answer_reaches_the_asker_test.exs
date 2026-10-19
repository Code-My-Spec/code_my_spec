defmodule CodeMySpec.Agents.Main.AnEscalatedAnswerReachesTheAskerTest do
  @moduledoc """
  b6380ea4. Reported: after main escalates a teammate's question, check_answer
  told the original asker "No question of yours has id ..." once the user had
  answered it.

  Driven through the same tools a real asker, main and the user use -
  ask_question, escalate_question, the inbox's own answering path, and
  check_answer - rather than the records underneath, because the report is
  about what each party's own tool call returns.

  Not reproduced here: with agent_id threaded through exactly as
  Plugs.AgentScope does in production, the asker's check_answer call finds
  the answer. Kept as a regression guard for that path rather than evidence
  of a fix, since nothing in lib/ needed to change to make it pass.
  """

  use CodeMySpecSpex.Case, async: true

  import CodeMySpecSpex.QuestionRoutingHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "the asker collects the user's decision after main hands the question up", context do
    id = ask(context, "Hard cutover or dual-write the CLI migration?", ~w(Cutover Dual-write))
    _ = main_escalates(context, id, "this changes what we ship, not a fact I can look up")
    user_answers(context, id, "Cutover")

    reply = collect(context, id)

    assert reply =~ "Cutover",
           """
           The asker's own check_answer call did not return the decision it was
           waiting on:

           #{reply}
           """
  end
end
