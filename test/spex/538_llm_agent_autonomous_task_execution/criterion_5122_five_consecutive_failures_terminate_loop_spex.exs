defmodule CodeMySpecSpex.Story538.Criterion5122Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 5122 — When evaluate_task returns the same feedback hash
  five times in a row in a session, the autonomous loop terminates
  and escalates.

  Covers Rule R8 (stuck-detection clause): each `{:ok, :invalid,
  feedback}` is hashed and compared against
  `session.last_eval_feedback_hash`. Matching hash → bump
  `eval_feedback_count`; differing hash → reset to 1. When the count
  reaches 5, the stop hook clears `session.continuous` and emits an
  allow with a `systemMessage` that names stuck-detection.

  ## Surface

  - `EvaluateTask` MCP tool — the same surface a manual-validation
    agent calls per Rule R4. Each `{:ok, :invalid, feedback}` result
    bumps the session-level counter via
    `Sessions.record_eval_feedback/3`.
  - `POST /api/hooks/stop` — the production webhook that observes
    `session.eval_feedback_count` and fires R8 when continuous is on
    + threshold hit.
  - `:persona_research_task_started` — shared given that creates a
    `personas_complete` manual task that fails by default (no persona
    exists yet), so every `EvaluateTask` call returns needs-work.

  ## What this asserts

  After 5 consecutive `evaluate_task` failures on the same task, the
  next stop hook:
  1. Does NOT block (allow path — the loop is over, not stalled).
  2. Surfaces a `systemMessage` that names "stuck-detection" so the
     agent (and the user via NotificationClient) know the loop ended
     by R8, not by R6 ("all work complete") or a regular allow.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "5 consecutive evaluate_task failures terminate the autonomous loop" do
    scenario "stop hook after the 5th needs-work emits the R8 termination signal" do
      given_ :persona_research_task_started

      given_ "continuous mode is on for this session", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)
        {:ok, context}
      end

      given_ "evaluate_task has returned needs-work 5 times in a row on this task",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        # Premise guards via pattern-match: if any call doesn't return
        # the expected non-error shape with needs-work language, the
        # setup hasn't established the state R8 reacts to and we want
        # the failure to surface here, not in a `then_` chasing the
        # downstream symptom.
        for _ <- 1..5 do
          {:reply, response, _frame} =
            EvaluateTask.execute(
              %{task_id: context.task_id, session_id: context.session_id},
              frame
            )

          false = response.isError
          body = TaskResponseHelpers.response_text(response)
          true = body =~ ~r/needs.work|not yet|missing|feedback/i
        end

        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response surfaces a stuck-detection signal and does NOT block",
            context do
        # Positive anchor: the systemMessage field must be present and
        # carry the stuck-detection language. This proves the response
        # actually came back from the R8 path; a missing field or null
        # response would fail this anchor before the refute below could
        # silently pass.
        system_message = context.response["systemMessage"]

        assert is_binary(system_message),
               "expected an R8 systemMessage to discriminate from a regular allow, got: " <>
                 inspect(context.response)

        assert system_message =~ ~r/stuck.detection/i,
               "expected the systemMessage to name stuck-detection, got:\n#{system_message}"

        refute context.response["decision"] == "block",
               "stuck-detection terminates the loop; the stop must not block, got: " <>
                 inspect(context.response)

        {:ok, context}
      end
    end
  end
end
