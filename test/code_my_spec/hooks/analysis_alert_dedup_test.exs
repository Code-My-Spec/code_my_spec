defmodule CodeMySpec.Hooks.AnalysisAlertDedupTest do
  @moduledoc """
  Who "already told" is about.

  `AnalysisAlert` says an analyzer run landed, once, and stays quiet until the
  problems move. The question this covers is *once per what*, and it had the
  wrong answer: the key was `{working_copy_id, session_id}`, and the comment
  above it read "two agents in one checkout are told independently".

  A Task-spawned subagent shares its parent's `session_id`. `PostToolUse` states
  that in its own moduledoc and keys file edits on
  `(external_session_id, agent_id, file_path)` because of it. So the two
  collided: whichever agent called a tool first took the alert, and the other
  was told nothing until the watermark moved. Story 890's criteria 2340 and 2341
  were false by construction, and no test looked — which is how it shipped.

  Deliberately not async: the dedup lives in `:persistent_term`, which is global
  to the VM, and two of these running at once would share it.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProblemsFixtures

  alias CodeMySpec.Hooks.AnalysisAlert

  setup do
    scope = full_scope_fixture()
    problem_fixture(scope, %{message: "something broke"})

    # Every key this file writes, not just the main agent's. `:persistent_term`
    # is global to the VM and nothing collects it, and each write costs a scan
    # proportional to how much is already in there — so a test that leaves
    # entries behind taxes every later one.
    copy = scope.active_working_copy_id

    on_exit(fn ->
      for agent <- [nil, "subagent-a", "subagent-b"] do
        :persistent_term.erase({AnalysisAlert, {copy, "s1", agent}})
      end
    end)

    %{scope: scope}
  end

  test "a subagent is told even though its parent already was", %{scope: scope} do
    # One session, two agents — the shape Claude Code produces when the main
    # agent spawns a Task. `nil` is the main agent.
    assert AnalysisAlert.check(scope, "s1", nil)

    assert AnalysisAlert.check(scope, "s1", "subagent-a"), """
    The subagent got nothing, because its parent had already been told and they
    share a session id. That is the collision story 890's criteria 2340 and 2341
    forbid — and the module's own comment claims it does not happen.
    """
  end

  test "and a second subagent is told too", %{scope: scope} do
    assert AnalysisAlert.check(scope, "s1", "subagent-a")
    assert AnalysisAlert.check(scope, "s1", "subagent-b")
  end

  test "but one agent is still told only once for the same problems", %{scope: scope} do
    assert AnalysisAlert.check(scope, "s1", "subagent-a")

    refute AnalysisAlert.check(scope, "s1", "subagent-a"), """
    Widening the key must not turn the alert into a line on every tool call.
    Dedup per agent is the point; no dedup at all is noise the model learns to
    skip, which costs the signal more permanently than missing it once.
    """
  end

  test "the main agent still dedupes against itself", %{scope: scope} do
    assert AnalysisAlert.check(scope, "s1", nil)
    refute AnalysisAlert.check(scope, "s1", nil)
  end

  test "and new problems reach an agent that was already told", %{scope: scope} do
    assert AnalysisAlert.check(scope, "s1", "subagent-a")
    refute AnalysisAlert.check(scope, "s1", "subagent-a")

    problem_fixture(scope, %{message: "something else broke", file_path: "lib/other.ex"})

    assert AnalysisAlert.check(scope, "s1", "subagent-a"),
           "the watermark moved and the agent was not told, so the dedup is silencing real news"
  end

  # This asserted the opposite until story 1042, and the change was the point
  # rather than a regression: an agent running under Alloy has an `agent_id` and
  # no session at all, so requiring the session meant `check/3` answered `nil`
  # for every internal agent no matter what its analyzers had found. Either
  # identity is now enough to be a recipient; neither is still nobody.
  test "an agent id alone is enough to be told" do
    scope = full_scope_fixture()
    problem_fixture(scope, %{message: "something broke", source: "credo"})
    copy = scope.active_working_copy_id
    on_exit(fn -> :persistent_term.erase({AnalysisAlert, {copy, nil, "an-alloy-agent"}}) end)

    assert AnalysisAlert.check(scope, nil, "an-alloy-agent")
  end

  test "and naming neither is nobody to have told", %{scope: scope} do
    refute AnalysisAlert.check(scope, nil, nil)
  end
end
