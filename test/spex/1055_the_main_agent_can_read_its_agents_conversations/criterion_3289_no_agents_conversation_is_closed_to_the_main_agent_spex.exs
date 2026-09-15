defmodule CodeMySpecSpex.Story1055.Criterion3289Spex do
  @moduledoc """
  Story 1055 — The main agent can read its agents' conversations.
  Criterion 3289 — No agent's conversation is closed to the main agent.

  Reading any agent's conversation on the project succeeds regardless of that
  agent's role or which working copy it runs on — the project is the
  boundary, not the working copy or the role.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "No agent's conversation is closed to the main agent" do
    scenario "No agent's conversation is closed to the main agent" do
      given_ "agents of every role are running across the project's working copies", context do
        coding = Fixtures.running_agent(context.scope, role: "coding", working_copy: "/tmp/copy-a")
        qa = Fixtures.running_agent(context.scope, role: "qa", working_copy: "/tmp/copy-b")
        product = Fixtures.running_agent(context.scope, role: "product", working_copy: "/tmp/copy-c")

        :ok = Fixtures.agent_said(context.scope, coding, "Coding agent turn")
        :ok = Fixtures.agent_said(context.scope, qa, "QA agent turn")
        :ok = Fixtures.agent_said(context.scope, product, "Product agent turn")

        {:ok, Map.merge(context, %{coding: coding, qa: qa, product: product})}
      end

      when_ "the main agent reads any one of their conversations", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        responses =
          Enum.map([context.coding, context.qa, context.product], fn agent ->
            {:reply, response, _frame} =
              ReadAgentConversation.execute(%{"agent_id" => agent.id}, frame)

            {agent, response}
          end)

        {:ok, Map.put(context, :responses, responses)}
      end

      then_ "it is not refused", context do
        for {agent, response} <- context.responses do
          refute response.isError,
                 "expected #{agent.role} agent on #{agent.working_copy} to be readable, got: #{inspect(response)}"
        end

        {:ok, context}
      end

      then_ "and the project is the boundary rather than the working copy or the role", context do
        for {_agent, response} <- context.responses do
          body = response_text(response)
          assert body =~ " agent turn"
        end

        {:ok, context}
      end
    end
  end
end
