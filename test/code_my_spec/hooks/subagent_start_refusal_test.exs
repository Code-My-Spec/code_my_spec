defmodule CodeMySpec.Hooks.SubagentStartRefusalTest do
  @moduledoc """
  A refusal that says what was wanted must also say what arrived.

  Four `subagent-start refused ... agent_id is required` in two days (3bc0a83a)
  could not be diagnosed from either side. `register/4` logged; the refusal path
  did not. So the only trace anywhere was the harness quoting the server's error
  message back at itself — which names the field that was wanted and nothing
  about the payload that was sent.

  That mattered because the refusal is rare, not systematic: `web.log` carries
  ten successful registrations over the same period, from ordinary Task-tool
  subagents. So Claude Code does send `agent_id` on the normal path, and
  whatever produces these four is an edge case.

  An edge case nobody can see is one nobody can fix, and the tempting move then
  is to make the field optional — which would buy quiet at the cost of R5a's
  runtime claim, since that keys off `Task.agent_id != nil`. Making the refusal
  observable is the cheaper half and it does not decide the contract.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import ExUnit.CaptureLog

  alias CodeMySpec.Hooks.SubagentStart

  describe "a refusal names what arrived" do
    test "a missing agent_id logs the fields that were present" do
      log =
        capture_log(fn ->
          assert {400, %{error: "agent_id is required"}} =
                   SubagentStart.handle(full_scope_fixture(), %{
                     "session_id" => "sess-1",
                     "agent_type" => "qa",
                     "hook_event_name" => "SubagentStart"
                   })
        end)

      assert log =~ "agent_id missing or blank"

      assert log =~ "agent_type, hook_event_name, session_id",
             "the whole point: the next occurrence says which fields Claude Code " <>
               "actually sent, which is what four refusals could not answer"
    end

    test "the session is named, so the refusal joins the rest of that session's log" do
      log =
        capture_log(fn ->
          SubagentStart.handle(full_scope_fixture(), %{
            "session_id" => "sess-correlate",
            "agent_type" => "qa"
          })
        end)

      assert log =~ "sess-correlate"
    end

    test "a missing session_id refuses the same way" do
      log =
        capture_log(fn ->
          assert {400, %{error: "session_id is required"}} =
                   SubagentStart.handle(full_scope_fixture(), %{"agent_id" => "a1"})
        end)

      assert log =~ "session_id missing or blank"
    end
  end

  describe "what must not end up in the log" do
    # Hook payloads carry prompts and transcripts. A refusal is written to a
    # file an operator greps; it has no business quoting the model's input.
    test "field values are named, but arbitrary payload values are not" do
      log =
        capture_log(fn ->
          SubagentStart.handle(full_scope_fixture(), %{
            "session_id" => "sess-2",
            "prompt" => "a secret the log must not carry",
            "transcript_path" => "/tmp/very/private/transcript.jsonl"
          })
        end)

      assert log =~ "prompt", "the key is useful — it says the field was present"
      refute log =~ "a secret the log must not carry"
      refute log =~ "/tmp/very/private/transcript.jsonl"
    end
  end

  # An empty string is not an id, and it arrives as one from a shell that
  # expanded an unset variable — the same shape as the `${CMS_HARNESS_ID}` case
  # the harness already guards against.
  test "a blank agent_id is refused, not registered" do
    assert {400, %{error: "agent_id is required"}} =
             SubagentStart.handle(full_scope_fixture(), %{
               "session_id" => "sess-3",
               "agent_id" => ""
             })
  end
end
