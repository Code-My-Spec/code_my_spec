defmodule CodeMySpecSpex.Story538.Criterion1502Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 1502 — When evaluate_task returns invalid feedback whose hash
  differs from the previously stored hash, or returns valid, the
  stuck-detection counter resets.

  No scenario was recorded against this criterion on the story — only the
  title. Translated mechanically from `Sessions.record_eval_feedback/3`'s
  own documented contract: "a match increments eval_feedback_count; a miss
  resets the count to 1." Covers the "differs" half.

  ## What is deliberately not covered here

  The "or returns valid" half collapses into R4's ordinary passing-evaluation
  path (criteria 1494/1495) the moment it is driven through the public
  surface: a task that passes is `:completed`, and nothing about *that*
  outcome is distinguishable from "the counter reset" without reading the
  session row directly, which a `then_` may not do. Asserting it here would
  either duplicate 1494/1495 or read the database. Left open for whoever
  implements this to decide whether a distinct observation is possible.

  ## The mechanism under test

  `session.eval_feedback_count` accumulates only while consecutive
  `evaluate_task` calls hash to the same `last_eval_feedback_hash`. A
  differing hash resets the count to 1 rather than adding to it — so
  1 failure with one feedback text, followed by 4 with a *different* text,
  must not read as "5 in a row" even though 5 `evaluate_task` calls were
  made in the session. Two different manual-validation tasks in the same
  session produce two different default feedback texts, which is the
  simplest way to get a differing hash without reaching into a checker's
  internals.

  If `technical_strategy`'s default feedback turns out not to be needs-work
  (`start_task` writes pre-made ADRs as a side effect, per its own given's
  comment), the premise guard inside the second `evaluate_task` loop fails
  loudly rather than the scenario passing vacuously.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A differing feedback hash resets the stuck-detection counter" do
    scenario "one failure on one task, then four on a different task, never reads as five in a row" do
      given_ :persona_research_task_started

      given_ "continuous mode is on for this session", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)
        {:ok, context}
      end

      given_ "evaluate_task fails once on the persona task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        false = response.isError

        true =
          TaskResponseHelpers.response_text(response) =~ ~r/needs.work|not yet|missing|feedback/i

        {:ok, context}
      end

      when_ "a different task in the same session then fails four times in a row", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, start_response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "technical_strategy",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        other_task_id = TaskResponseHelpers.extract_task_id!(start_response)

        for _ <- 1..4 do
          {:reply, response, _frame} =
            EvaluateTask.execute(
              %{task_id: other_task_id, session_id: context.session_id},
              frame
            )

          false = response.isError

          true =
            TaskResponseHelpers.response_text(response) =~
              ~r/needs.work|not yet|missing|feedback/i
        end

        {:ok, context}
      end

      then_ "the next stop hook does not report stuck-detection", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        system_message = response["systemMessage"]

        refute is_binary(system_message) and system_message =~ ~r/stuck.detection/i,
               """
               5 evaluate_task calls landed in this session, but the last 4 differed in
               feedback from the 1st — if the counter is counting *any* failure rather
               than *consecutive same-hash* failures, this fires R8 a call early. Got:
               #{inspect(response)}
               """

        {:ok, context}
      end
    end
  end
end
