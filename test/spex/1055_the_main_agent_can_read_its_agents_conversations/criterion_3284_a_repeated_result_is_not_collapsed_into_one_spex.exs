defmodule CodeMySpecSpex.Story1055.Criterion3284Spex do
  @moduledoc """
  Story 1055 — The main agent can read its agents' conversations.
  Criterion 3284 — A repeated result is not collapsed into one.

  Two identical tool results, back to back, both come back — not one row
  standing in for both.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @result_text "no changes detected"

  spex "A repeated result is not collapsed into one" do
    scenario "A repeated result is not collapsed into one" do
      given_ "an agent received the same tool result twice in a row", context do
        agent = Fixtures.running_agent(context.scope, role: "coding")

        :ok = Fixtures.agent_tool_call(context.scope, agent, "call-1", "check_status", %{})
        :ok = Fixtures.agent_tool_result(context.scope, agent, "call-1", "check_status", @result_text)

        :ok = Fixtures.agent_tool_call(context.scope, agent, "call-2", "check_status", %{})
        :ok = Fixtures.agent_tool_result(context.scope, agent, "call-2", "check_status", @result_text)

        {:ok, Map.put(context, :agent, agent)}
      end

      when_ "the main agent reads those turns", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ReadAgentConversation.execute(%{"agent_id" => context.agent.id}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "both results are shown", context do
        refute context.response.isError,
               "expected both results, got: #{inspect(context.response)}"

        body = response_text(context.response)
        occurrences = body |> String.split(@result_text) |> length() |> Kernel.-(1)

        assert occurrences >= 2,
               """
               expected the identical result to appear twice, not collapsed into one.

               got #{occurrences} occurrence(s) in:
               #{body}
               """

        {:ok, context}
      end

      then_ "and their identicalness is visible rather than being deduplicated away", context do
        body = response_text(context.response)

        assert body =~ "call-1"
        assert body =~ "call-2"

        {:ok, context}
      end
    end
  end
end
