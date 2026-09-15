defmodule CodeMySpecSpex.Story1055.Criterion3287Spex do
  @moduledoc """
  Story 1055 — The main agent can read its agents' conversations.
  Criterion 3287 — A broad query is cut to the limit rather than returned
  whole.

  A read that would exceed the answer's token budget comes back truncated,
  and says so — the main agent is told it was cut rather than left to assume
  it saw everything.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  # Long enough, repeated enough times, to exceed any reasonable per-answer
  # token budget without needing to seed literally thousands of rows.
  @long_line String.duplicate("the ledger write retried and failed again. ", 40)

  spex "A broad query is cut to the limit rather than returned whole" do
    scenario "A broad query is cut to the limit rather than returned whole" do
      given_ "the main agent asks for more turns than the token limit allows", context do
        agent = Fixtures.running_agent(context.scope, role: "coding")

        for n <- 1..200 do
          :ok = Fixtures.agent_said(context.scope, agent, "Turn #{n}: #{@long_line}")
        end

        {:ok, Map.put(context, :agent, agent)}
      end

      when_ "the query is answered", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ReadAgentConversation.execute(%{"agent_id" => context.agent.id}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the result is cut to the limit", context do
        refute context.response.isError,
               "expected a truncated read, got: #{inspect(context.response)}"

        body = response_text(context.response)

        refute body =~ "Turn 1:",
               "expected the earliest turns to be cut from a broad, over-budget query"

        {:ok, context}
      end

      then_ "and the main agent is told it was cut rather than being left to assume it saw everything",
            context do
        body = response_text(context.response)

        assert body =~ "truncated",
               """
               expected the response to say it was cut, not leave the caller to assume
               it saw the whole conversation.

               got:
               #{body}
               """

        {:ok, context}
      end
    end
  end
end
