defmodule CodeMySpecSpex.Story555.Criterion5104Spex do
  @moduledoc """
  Story 555 — Validation Pipeline Redesign: Stop Hook Core Behaviors
  Criterion 5104 — When the session is in continuous mode and the
  current task passes validation but more actionable requirements
  exist in the graph, the stop is blocked with a get_next_requirement
  instruction.

  StopController's `maybe_continue_with_next_task/3` checks
  `state.continuous == true` + `RequirementGraph.next_actionable/1`
  returning a non-empty list. When both are true, it returns a block
  with the instruction to call `get_next_requirement`.

  A `:synced_context_component` produces a component that has lots of
  unsatisfied requirements (test file, implementation, tests passing,
  reviews, etc.), so `next_actionable/1` will have candidates. The
  task itself has no `session_type`, so `TaskEvaluator` short-circuits
  with `{:ok, :valid}` and the continuous-mode branch kicks in.

  No pipeline cassette needed: task started_at is set 10s in the
  future, so `resolve_changed_files` returns [] and the pipeline is
  skipped.
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Continuous mode blocks with next-task instruction" do
    scenario "validation passes + more work available → block with get_next_requirement" do
      given_ :synced_context_component

      given_ "a continuous session has an active task that will evaluate clean",
             context do
        external_id = "spex-#{System.unique_integer([:positive])}"

        future =
          DateTime.utc_now()
          |> DateTime.add(10, :second)
          |> DateTime.truncate(:second)

        session =
          Fixtures.session_with_task_fixture(
            context.scope,
            %{
              external_conversation_id: external_id,
              state: %{"continuous" => true}
            },
            %{started_at: future}
          )

        {:ok, Map.merge(context, %{session: session, external_id: external_id})}
      end

      when_ "the stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.external_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked with a get_next_requirement instruction",
            context do
        assert context.response["decision"] == "block",
               "continuous mode with more work must block the stop, got: #{inspect(context.response)}"

        reason = context.response["reason"]

        assert is_binary(reason), "reason must be present, got: #{inspect(reason)}"

        assert reason =~ "get_next_requirement",
               "reason must direct the agent to call get_next_requirement, got:\n#{reason}"

        :ok
      end
    end
  end
end
