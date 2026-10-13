defmodule CodeMySpec.Agents.Main.MainSeesWhatProductIsDesigningTest do
  @moduledoc """
  `list_agent_work` names the epic product is designing (a31f1cd6, step 4d).

  Main dispatches epics, so it needs to see which one product is still on.
  Coding and QA hold their team's epic too, but they build it; no line for them.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.McpServers.MainAgent.AgentWorkMapper
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    RecordingAgentTransport.listen(context)
    :ok
  end

  defp agent(scope, role, attrs) do
    {:ok, agent} =
      AgentsRepository.create_agent(
        scope,
        Map.merge(
          %{
            provider: "anthropic",
            engine: :alloy,
            role: role,
            status: :running,
            working_copy: "/tmp/designing-#{System.unique_integer([:positive])}",
            working_copy_id: scope.active_working_copy_id
          },
          attrs
        )
      )

    AgentPresence.present(agent)

    agent
  end

  defp listing(scope), do: scope |> MainAgent.list_agent_work() |> AgentWorkMapper.text()

  test "product holding an epic reads as designing it; coding holding one does not", ctx do
    designed = Fixtures.epic_fixture(ctx.scope, %{name: "Checkout redesign"})
    built = Fixtures.epic_fixture(ctx.scope, %{name: "Billing export"})

    agent(ctx.scope, "product", %{epic_id: designed.id})
    agent(ctx.scope, "coding", %{epic_id: built.id})

    text = listing(ctx.scope)

    assert text =~ "\n  designing: Checkout redesign\n"
    refute text =~ "Billing export"
  end

  test "product with no epic gets no designing line", ctx do
    agent(ctx.scope, "product", %{})

    refute listing(ctx.scope) =~ "designing:"
  end
end
