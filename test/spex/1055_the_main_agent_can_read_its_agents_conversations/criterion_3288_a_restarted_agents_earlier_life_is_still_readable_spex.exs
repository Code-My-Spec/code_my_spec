defmodule CodeMySpecSpex.Story1055.Criterion3288Spex do
  @moduledoc """
  Story 1055 — The main agent can read its agents' conversations.
  Criterion 3288 — A restarted agent's earlier life is still readable.

  An agent restarted (through the real `restart_agent` tool, more than once)
  keeps one conversation across those restarts — turns from before them are
  still there afterward.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A restarted agent's earlier life is still readable" do
    scenario "A restarted agent's earlier life is still readable" do
      given_ "an agent has been restarted several times", context do
        # A real restart picks a connected provider to relaunch under
        # (`Agents.restart_agent/2` refuses `:not_connected` otherwise) —
        # this criterion is about the conversation surviving the restart, not
        # about provider selection, so the connection is just setup.
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :zai)

        agent = Fixtures.running_agent(context.scope, role: "coding")
        frame = %Frame{assigns: %{current_scope: context.scope}}

        :ok = Fixtures.agent_said(context.scope, agent, "First life: started the refund fix")

        {:reply, first_restart, _frame} =
          RestartAgent.execute(%{"agent_id" => agent.id, "reason" => "seemed stuck"}, frame)

        refute first_restart.isError,
               "expected the first restart to succeed, got: #{inspect(first_restart)}"

        :ok = Fixtures.agent_said(context.scope, agent, "Second life: retried the refund fix")

        {:reply, second_restart, _frame} =
          RestartAgent.execute(
            %{"agent_id" => agent.id, "reason" => "stuck again on the same step"},
            frame
          )

        refute second_restart.isError,
               "expected the second restart to succeed, got: #{inspect(second_restart)}"

        :ok = Fixtures.agent_said(context.scope, agent, "Third life: shipped the refund fix")

        {:ok, Map.put(context, :agent, agent)}
      end

      when_ "the main agent reads that agent's history", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ReadAgentConversation.execute(%{"agent_id" => context.agent.id}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "turns from before the restarts are available", context do
        refute context.response.isError,
               "expected the full history across restarts, got: #{inspect(context.response)}"

        body = response_text(context.response)

        assert body =~ "First life: started the refund fix"
        assert body =~ "Second life: retried the refund fix"
        assert body =~ "Third life: shipped the refund fix"

        {:ok, context}
      end

      then_ "and they did not go away with the processes that produced them", context do
        body = response_text(context.response)

        assert body =~ to_string(context.agent.id),
               "expected the history to still be this same agent's, not a fresh one's"

        {:ok, context}
      end
    end
  end
end
