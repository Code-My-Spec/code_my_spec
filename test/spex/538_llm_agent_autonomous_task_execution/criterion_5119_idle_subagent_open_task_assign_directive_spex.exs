defmodule CodeMySpecSpex.Story538.Criterion5119Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 5119 — When the session has an open task and an idle alive
  sub-agent, the stop is blocked with a directive instructing the main
  agent to assign the sub-agent to the open task.

  Covers Rule R5b: "The session has an open task AND an alive idle
  sub-agent: block with a directive instructing the main agent to
  assign the sub-agent to the open task; once assigned, main agent
  stops and further stops happen via the sub-agent's own lifecycle."

  ## Surface

  Sub-agent registration goes through the production webhook
  `POST /api/hooks/subagent-start` (same hook Claude Code's
  SubagentStart event hits). The open task is a real main-agent task
  driven by the `start_task` MCP tool via the
  `:context_spec_task_started` shared given.

  ## What this asserts

  In a continuous-mode session with:
  - one active main-agent task (`agent_id` is nil), AND
  - an alive registered sub-agent with no task assigned to its
    `agent_id`

  ...the stop hook returns a block whose reason names the `assign`
  directive and the specific idle `agent_id`, so the main agent can
  hand the work off without inventing the sub-agent identity itself.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Idle alive sub-agent + open main task → block + assign directive" do
    scenario "stop hook directs the main agent to assign the idle sub-agent to the open task" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "the agent enabled continuous mode for this session", context do
        :ok = Fixtures.start_continuous_mode(context.scope, context.session_id)
        {:ok, context}
      end

      given_ "an alive sub-agent is registered on the session and is idle (no task assigned)",
             context do
        agent_id = "spex-5119-subagent-#{System.unique_integer([:positive])}"

        registration =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/subagent-start", %{
            "session_id" => context.session_id,
            "agent_id" => agent_id,
            "agent_name" => "codemyspec:code-writer"
          })
          |> Phoenix.ConnTest.json_response(200)

        # Sub-agent registration must echo the agent_id back — otherwise the
        # hook silently failed (e.g. session not found, validation error) and
        # the rest of the scenario would test the wrong baseline state.
        assert registration["agent_id"] == agent_id,
               "expected registration to echo agent_id, got: #{inspect(registration)}"

        {:ok, Map.put(context, :idle_agent_id, agent_id)}
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

      then_ "the stop is blocked", context do
        assert context.response["decision"] == "block",
               "open main task + idle sub-agent must block — got: #{inspect(context.response)}"

        {:ok, context}
      end

      and_ "the block reason instructs the main agent to assign the idle sub-agent",
           context do
        reason = context.response["reason"]

        assert is_binary(reason),
               "expected a reason string, got: #{inspect(context.response)}"

        # The directive must name the assign action — otherwise the main
        # agent would invent its own delegation mechanism.
        assert reason =~ "assign",
               "expected the directive to name `assign`, got reason:\n#{reason}"

        # The specific idle sub-agent's id must appear in the directive
        # so the main agent doesn't have to discover it via
        # list_session_subagents first.
        assert reason =~ context.idle_agent_id,
               "expected the directive to name idle agent_id `#{context.idle_agent_id}`, got reason:\n#{reason}"

        {:ok, context}
      end
    end
  end
end
