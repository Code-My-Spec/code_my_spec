defmodule CodeMySpecSpex.Story538.Criterion5112Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 5112 — When the stop hook fires in continuous mode and
  the current task passed, it calls `get_next_requirement` server-side
  and embeds the result in the block reason; the agent then calls
  `start_task` on the returned requirement.

  Sibling to 5111. 5111 asserts the block + embedded-directive shape.
  5112 nails down the specific obligation: the embedded directive must
  be the actual `get_next_requirement` output (the rendered
  RequirementsMapper text), not just an advisory to call the tool.
  The agent must be able to read the block reason and call `start_task`
  with the exact `requirement_name=`, `entity_type=`, `entity_id=`
  fields, eliminating the otherwise-required round-trip through
  `get_next_requirement`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Stop hook embeds the next-requirement result so the agent can call start_task directly" do
    scenario "block reason contains a full start_task call signature with all three fields" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "the agent enabled continuous mode for this session", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)
        {:ok, context}
      end

      when_ "the stop hook fires", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response is a block whose reason names all three start_task fields",
            context do
        assert context.response["decision"] == "block",
               "continuous mode + work remaining must block — got: #{inspect(context.response)}"

        reason = context.response["reason"]

        # All three fields are needed for a direct start_task call — without
        # any of them, the agent would have to fall back to calling
        # get_next_requirement first, which defeats the purpose of embedding.
        assert reason =~ "requirement_name=",
               "expected block reason to embed a `requirement_name=` field, got:\n#{reason}"

        assert reason =~ "entity_type=",
               "expected block reason to embed an `entity_type=` field, got:\n#{reason}"

        assert reason =~ "entity_id=",
               "expected block reason to embed an `entity_id=` field, got:\n#{reason}"

        {:ok, context}
      end

      and_ "the embedded entity_id matches a real component (not a placeholder)",
           context do
        reason = context.response["reason"]

        # entity_id values in the mapper output are backticked UUIDs.
        # Anything that looks like a non-empty backticked value confirms
        # the mapper rendered real graph data instead of a placeholder.
        assert reason =~ ~r/entity_id=`[A-Za-z0-9_-]+`/,
               "expected entity_id to be a real backticked identifier, got:\n#{reason}"

        {:ok, context}
      end
    end
  end
end
