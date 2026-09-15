defmodule CodeMySpecSpex.Story1055.Criterion3280Spex do
  @moduledoc """
  Story 1055 — The main agent can read its agents' conversations.
  Criterion 3280 — The main agent reads a stuck agent's recent turns.

  An agent that has said several things on its own conversation is read back,
  in the order it said them, through one MCP tool call — the main agent never
  has to send the agent anything to find out what it did.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The main agent reads a stuck agent's recent turns" do
    scenario "The main agent reads a stuck agent's recent turns" do
      given_ "an agent has stopped making progress, several turns into its work", context do
        agent = Fixtures.running_agent(context.scope, role: "coding")

        :ok = Fixtures.agent_said(context.scope, agent, "Reading the failing test")
        :ok = Fixtures.agent_said(context.scope, agent, "Editing lib/foo.ex")
        :ok = Fixtures.agent_said(context.scope, agent, "Running mix test")

        {:ok, Map.put(context, :agent, agent)}
      end

      when_ "the main agent reads that agent's recent turns", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ReadAgentConversation.execute(%{"agent_id" => context.agent.id}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it can see what the agent did, in the order it did it", context do
        refute context.response.isError,
               "expected success reading #{context.agent.id}'s conversation, got: #{inspect(context.response)}"

        body = response_text(context.response)

        assert body =~ "Reading the failing test"
        assert body =~ "Editing lib/foo.ex"
        assert body =~ "Running mix test"

        {reading_at, _} = :binary.match(body, "Reading the failing test")
        {editing_at, _} = :binary.match(body, "Editing lib/foo.ex")
        {running_at, _} = :binary.match(body, "Running mix test")

        assert reading_at < editing_at,
               "expected the read to preserve turn order, got: #{body}"

        assert editing_at < running_at,
               "expected the read to preserve turn order, got: #{body}"

        {:ok, context}
      end

      then_ "and it did not have to ask the agent to explain itself", context do
        assert Fixtures.messages_to_agent(context.scope, context.agent.id) == [],
               "the main agent sent something to the agent instead of reading its own turns"

        {:ok, context}
      end
    end
  end
end
