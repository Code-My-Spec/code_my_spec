defmodule CodeMySpecSpex.Story1055.Criterion3282Spex do
  @moduledoc """
  Story 1055 — The main agent can read its agents' conversations.
  Criterion 3282 — A question about a long conversation is answered without
  reading it all.

  "When did this agent last call this tool" is answered directly, not by
  handing back the whole transcript for the caller to search.

  The conversation is seeded at a few dozen turns rather than the "thousands"
  the criterion names — enough to prove the answer is targeted rather than a
  full dump, without paying thousands of DB writes on every suite run. See
  `bdd/spex/environment.md`'s note on pragmatic shortcuts.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A question about a long conversation is answered without reading it all" do
    scenario "A question about a long conversation is answered without reading it all" do
      given_ "an agent has a conversation with many turns", context do
        agent = Fixtures.running_agent(context.scope, role: "coding")

        for n <- 1..20 do
          :ok = Fixtures.agent_said(context.scope, agent, "Filler turn #{n} before the call")
        end

        :ok =
          Fixtures.agent_tool_call(context.scope, agent, "call-provision", "run_provisioning_step", %{
            "step" => "dns"
          })

        :ok =
          Fixtures.agent_tool_result(
            context.scope,
            agent,
            "call-provision",
            "run_provisioning_step",
            "dns published"
          )

        for n <- 1..20 do
          :ok = Fixtures.agent_said(context.scope, agent, "Filler turn #{n} after the call")
        end

        {:ok, Map.put(context, :agent, agent)}
      end

      when_ "the main agent asks when that agent last called a particular tool", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ReadAgentConversation.execute(
            %{"agent_id" => context.agent.id, "last_call_of" => "run_provisioning_step"},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it gets that answer", context do
        refute context.response.isError,
               "expected an answer for #{context.agent.id}, got: #{inspect(context.response)}"

        body = response_text(context.response)

        assert body =~ "run_provisioning_step"
        assert body =~ "dns published"

        {:ok, context}
      end

      then_ "and it does not have to read the conversation to find it", context do
        body = response_text(context.response)

        refute body =~ "Filler turn",
               """
               expected a targeted answer, not the whole transcript.

               got:
               #{body}
               """

        {:ok, context}
      end
    end
  end
end
