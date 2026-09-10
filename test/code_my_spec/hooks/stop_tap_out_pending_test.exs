defmodule CodeMySpec.Hooks.StopTapOutPendingTest do
  @moduledoc """
  The stop hook's own copy of the rule `StopDecision.wake/2` and
  `decide_with_key/3` already hold for an agent we run: a session with a
  tap-out decision outstanding is allowed to stop without running validation.

  `session.continuous` stays `true` until the decision lands, so without this
  every other branch in `do_decide/6` reads "keep going" and
  `maybe_continue_with_next_task/3` would block the stop with more work on
  every single hook while a human has not answered yet — the session-keyed
  shape of the same hammering `Notifications.awaiting_answer?/1` exists to
  prevent for an agent we run.

  Checked first in the `cond`, so this never reaches the analyzers — no
  recorded output, no working copy, no cassette needed.
  """
  # `config/test.exs` runs Logger at :warning, which drops the `Logger.info`
  # this test reads before `capture_log` ever sees it. Raising the real level
  # is node-global, so this stays `async: false` rather than racing whatever
  # else is asserting silence at :info elsewhere.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.SessionsFixtures
  import ExUnit.CaptureLog

  alias CodeMySpec.Hooks.Stop

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  test "a session with a pending tap-out is allowed, and nothing else runs" do
    scope = full_scope_fixture()

    session =
      session_fixture(scope, %{
        external_conversation_id: "tap-out-pending-#{System.unique_integer([:positive])}",
        continuous: true,
        state: %{"pending_tap_out" => %{"id" => "req-1", "status" => "pending"}}
      })

    log =
      capture_log([level: :info], fn ->
        assert Stop.decide(scope, %{"session_id" => session.external_conversation_id}) == %{},
               "a pending tap-out has to answer allow — a session with a decision " <>
                 "outstanding can act on nothing else until it hears back"
      end)

    assert log =~ "Tap-out request pending"
  end
end
