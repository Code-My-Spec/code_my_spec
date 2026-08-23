defmodule CodeMySpecSpex.Story538.Criterion5111Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 5111 — When continuous mode is on and the current task
  passes, the stop is blocked with the next requirement embedded in
  the block reason.

  Covers Rule R3: "When the stop hook fires in continuous mode AND
  the current task passed validation AND there is actionable work,
  the hook calls get_next_requirement server-side and embeds the
  result in the block reason."

  ## Surface

  Continuous mode is enabled via the real `cms implement` surface —
  POST /api/skills/start with `skill: "implement"` — bridged through
  `Fixtures.start_continuous_mode/2`. The stop hook is then fired
  against a passing task; the response must be a block whose reason
  contains the next-requirement directive, not the generic "call
  get_next_requirement" advisory.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Continuous mode on + passing task → block with next requirement embedded" do
    scenario "stop hook embeds the next-requirement directive in the block reason" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "the agent enabled continuous mode for this session", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)
        {:ok, context}
      end

      when_ "the stop hook fires with no additional file writes", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the stop is blocked", context do
        assert context.response["decision"] == "block",
               "continuous mode + passing task must block — got: #{inspect(context.response)}"

        {:ok, context}
      end

      and_ "the block reason embeds the next-requirement directive", context do
        reason = context.response["reason"]

        assert is_binary(reason),
               "expected a reason string — got: #{inspect(context.response)}"

        # The mapper renders an actionable directive — at minimum, a
        # `start_task` call signature with a real entity_id. The
        # generic "call get_next_requirement" pre-538 reason would
        # NOT include `start_task` + `entity_id=` markers.
        assert reason =~ "start_task",
               "expected the embedded directive to name `start_task`, got reason:\n#{reason}"

        assert reason =~ "entity_id=",
               "expected the embedded directive to name an entity_id, got reason:\n#{reason}"

        {:ok, context}
      end
    end
  end
end
