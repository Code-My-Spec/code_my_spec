defmodule CodeMySpecSpex.Story1055.Criterion3301Spex do
  @moduledoc """
  Story 1055 — The main agent can read its agents' conversations.
  Criterion 3301 — A query inside the limit comes back whole.

  The counterpart to 3287: a read that fits comfortably inside the answer's
  token budget comes back complete, and is not marked as cut.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A query inside the limit comes back whole" do
    scenario "A query inside the limit comes back whole" do
      given_ "the main agent asks for a number of turns that fits inside the token limit", context do
        agent = Fixtures.running_agent(context.scope, role: "coding")

        for n <- 1..3 do
          :ok = Fixtures.agent_said(context.scope, agent, "Turn #{n}: short update")
        end

        {:ok, Map.put(context, :agent, agent)}
      end

      when_ "the query is answered", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ReadAgentConversation.execute(%{"agent_id" => context.agent.id}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "every turn asked for is returned", context do
        refute context.response.isError,
               "expected a complete read, got: #{inspect(context.response)}"

        body = response_text(context.response)

        for n <- 1..3 do
          assert body =~ "Turn #{n}: short update"
        end

        {:ok, context}
      end

      then_ "and the result is not marked as cut", context do
        body = response_text(context.response)

        refute body =~ "truncated",
               """
               expected a complete read with no truncation marker.

               got:
               #{body}
               """

        {:ok, context}
      end
    end
  end
end
