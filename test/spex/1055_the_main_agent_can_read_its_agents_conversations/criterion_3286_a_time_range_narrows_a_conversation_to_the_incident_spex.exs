defmodule CodeMySpecSpex.Story1055.Criterion3286Spex do
  @moduledoc """
  Story 1055 — The main agent can read its agents' conversations.
  Criterion 3286 — A time range narrows a conversation to the incident.

  Asking for an agent's turns within a known window gets only the turns from
  that window, not the turns from before it.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A time range narrows a conversation to the incident" do
    scenario "A time range narrows a conversation to the incident" do
      given_ "the main agent is looking into something that happened in a known window", context do
        agent = Fixtures.running_agent(context.scope, role: "coding")

        :ok = Fixtures.agent_said(context.scope, agent, "Before the incident: routine sync")
        :ok = Fixtures.age_agent_messages(context.scope, agent, 2 * 24 * 3600)

        :ok = Fixtures.agent_said(context.scope, agent, "During the incident: ledger write failed")

        window_start = DateTime.add(DateTime.utc_now(), -3600, :second)
        window_end = DateTime.add(DateTime.utc_now(), 3600, :second)

        {:ok,
         context
         |> Map.put(:agent, agent)
         |> Map.put(:window_start, window_start)
         |> Map.put(:window_end, window_end)}
      end

      when_ "it asks for that agent's turns within that window", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ReadAgentConversation.execute(
            %{
              "agent_id" => context.agent.id,
              "since" => DateTime.to_iso8601(context.window_start),
              "until" => DateTime.to_iso8601(context.window_end)
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it gets only the turns from that window", context do
        refute context.response.isError,
               "expected a windowed read, got: #{inspect(context.response)}"

        body = response_text(context.response)

        assert body =~ "During the incident: ledger write failed"

        refute body =~ "Before the incident: routine sync",
               """
               expected only turns inside the window.

               got:
               #{body}
               """

        {:ok, context}
      end
    end
  end
end
