defmodule CodeMySpecSpex.Story704.Criterion6090Spex do
  @moduledoc """
  Story 704 — Agent administers their session
  Criterion 6090 — Registration older than TTL is pruned on next read.

  Covers Rule 2's failure path: a sub-agent whose `last_heartbeat_at`
  exceeds the configured TTL does not appear in `list_session_subagents`.
  The seed uses `Fixtures.register_subagent_with_heartbeat` to plant
  a registration with an old heartbeat without manipulating the clock.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Registration older than TTL is pruned on next read", criterion: 435 do
    scenario "sub-agent with heartbeat older than 10 min is absent from list_session_subagents" do
      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "a session with a sub-agent whose heartbeat is older than the configured TTL",
             context do
        session_id = "spex-6090-#{System.unique_integer([:positive])}"
        agent_id = "stale-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

        # Heartbeat 30 minutes ago — well past the 10-minute default TTL
        {:ok, _session} =
          Fixtures.register_subagent_with_heartbeat(context.scope, session_id, %{
            agent_id: agent_id,
            agent_name: "@stale",
            last_heartbeat_at:
              DateTime.utc_now()
              |> DateTime.add(-30 * 60, :second)
              |> DateTime.truncate(:second)
          })

        {:ok, Map.merge(context, %{session_id: session_id, agent_id: agent_id})}
      end

      when_ "the agent calls list_session_subagents", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "list_session_subagents",
            %{session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the stale registration is absent from the response", context do
        # Anchor: the response rendered as a real header (not an error)
        assert context.response_text =~ "No registered sub-agents" or
                 context.response_text =~ "Registered Sub-agents",
               "expected response to be a real list header, got: #{context.response_text}"

        refute context.response_text =~ context.agent_id,
               "expected stale sub-agent #{context.agent_id} to be pruned, got:\n#{context.response_text}"

        {:ok, context}
      end
    end
  end
end
