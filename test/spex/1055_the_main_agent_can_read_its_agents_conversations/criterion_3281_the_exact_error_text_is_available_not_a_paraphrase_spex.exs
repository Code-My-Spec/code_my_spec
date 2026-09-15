defmodule CodeMySpecSpex.Story1055.Criterion3281Spex do
  @moduledoc """
  Story 1055 — The main agent can read its agents' conversations.
  Criterion 3281 — The exact error text is available, not a paraphrase.

  A failed tool call is read back with the tool, its arguments, and the error
  exactly as the provider returned it — not a summary of it.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @error_text """
  1) test refunds land on the ledger (RefundsTest)
     ** (RuntimeError) ledger service unreachable: :econnrefused
     lib/refunds.ex:42: Refunds.post/1
  """

  spex "The exact error text is available, not a paraphrase" do
    scenario "The exact error text is available, not a paraphrase" do
      given_ "an agent called a tool and the call failed", context do
        agent = Fixtures.running_agent(context.scope, role: "coding")

        :ok =
          Fixtures.agent_tool_call(context.scope, agent, "call-1", "run_mix_test", %{
            "path" => "test/refunds_test.exs"
          })

        :ok =
          Fixtures.agent_tool_result(context.scope, agent, "call-1", "run_mix_test", @error_text,
            failed?: true
          )

        {:ok, Map.put(context, :agent, agent)}
      end

      when_ "the main agent reads that turn", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ReadAgentConversation.execute(%{"agent_id" => context.agent.id}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it sees the tool that was called and the arguments it was given", context do
        refute context.response.isError,
               "expected success reading #{context.agent.id}'s conversation, got: #{inspect(context.response)}"

        body = response_text(context.response)

        assert body =~ "run_mix_test"
        assert body =~ "test/refunds_test.exs"

        {:ok, context}
      end

      then_ "it sees the error exactly as it came back", context do
        body = response_text(context.response)

        assert body =~ @error_text,
               """
               expected the exact provider error text, not a paraphrase of it.

               wanted:
               #{@error_text}

               got:
               #{body}
               """

        {:ok, context}
      end
    end
  end
end
