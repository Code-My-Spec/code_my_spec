defmodule CodeMySpec.AgentPerformance.MessageKindTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentPerformance.MessageKind

  test "the system's notices are told apart from a message by their opening text" do
    assert MessageKind.of("operator", "Eligible work is available. Call get_next_requirement") ==
             :work_offer

    assert MessageKind.of("operator", "Your exunit run finished: 1 blocking problem") == :analysis
    assert MessageKind.of("operator", "Check-in.\nNeeds you:") == :check_in

    assert MessageKind.of("operator", "Your turn is done and the loop is still running.") ==
             :turn_end

    assert MessageKind.of("operator", "The harness restarted. No turn of yours") ==
             :harness_restart

    assert MessageKind.of("operator", "Your last turn failed: codex exec failed") == :failed_turn

    assert MessageKind.of("operator", "Fix these problems before stopping: credo (3)") ==
             :problems

    assert MessageKind.of("operator", "Working copy 5375's team is free: story 1023 landed") ==
             :team_free
  end

  test "free text is a message, and a restart or promotion notice is named by its sender" do
    assert MessageKind.of("operator", "Please re-run QA on 1112 after the fix lands.") == :message
    assert MessageKind.of("system:restart", "Restart performed. Reason: stuck") == :restart
    assert MessageKind.of("promotion-notice", "Story 1023 landed") == :promotion
    assert MessageKind.intervention?(:message) and MessageKind.intervention?(:restart)
    refute MessageKind.intervention?(:work_offer)
  end
end
