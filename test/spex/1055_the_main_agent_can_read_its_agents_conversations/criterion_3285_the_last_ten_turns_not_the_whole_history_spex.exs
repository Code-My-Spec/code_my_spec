defmodule CodeMySpecSpex.Story1055.Criterion3285Spex do
  @moduledoc """
  Story 1055 — The main agent can read its agents' conversations.
  Criterion 3285 — The last ten turns, not the whole history.

  Asking for the last ten turns of a longer conversation gets exactly those
  ten — not the full history to page through.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The last ten turns, not the whole history" do
    scenario "The last ten turns, not the whole history" do
      given_ "an agent has a long conversation", context do
        agent = Fixtures.running_agent(context.scope, role: "coding")

        for n <- 1..15 do
          :ok = Fixtures.agent_said(context.scope, agent, "Turn #{n}")
        end

        {:ok, Map.put(context, :agent, agent)}
      end

      when_ "the main agent asks for its last ten turns", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ReadAgentConversation.execute(
            %{"agent_id" => context.agent.id, "limit" => 10},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it gets those ten", context do
        refute context.response.isError,
               "expected the last ten turns, got: #{inspect(context.response)}"

        body = response_text(context.response)

        for n <- 6..15 do
          assert body =~ "Turn #{n}",
                 "expected Turn #{n} among the last ten, got: #{body}"
        end

        {:ok, context}
      end

      then_ "and it is not given the conversation to read through", context do
        body = response_text(context.response)

        for n <- 1..5 do
          refute Regex.match?(~r/\bTurn #{n}\b/, body),
                 "expected only the last ten turns, but found Turn #{n} in: #{body}"
        end

        {:ok, context}
      end
    end
  end
end
