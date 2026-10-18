defmodule CodeMySpecSpex.Story1059.Criterion2114Spex do
  @moduledoc "Settled and off agents are counts with a detail lookup"
  use CodeMySpecSpex.Case
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpecSpex.CompactCadenceHelpers, as: Compact
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    :ok = Fixtures.install_recording_agent_transport(context)
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Settled and off agents are counts with a detail lookup", criterion: 2114 do
    scenario "Settled and off agents are counts with a detail lookup" do
      given_ "a large existing fleet with deliberately off seats", context do
        context = Compact.fleet(context, 25)

        for agent <- Enum.take(context.agents, 5) do
          Compact.call(context, "turn_off_agent", %{agent_id: agent.id, reason: "Operator hold"})
        end

        {:ok, context}
      end

      when_ "main asks for a check-in", context do
        {:ok, Compact.report(context)}
      end

      then_ "only counts appear and the suggested lookup contains the omitted detail", context do
        assert context.report =~ "20 settled"
        assert context.report =~ "5 off"
        assert context.report =~ "list_agent_work({})"
        assert byte_size(context.report) < 700
        for agent <- context.agents, do: refute(context.report =~ agent.id)
        detail = Compact.call(context, ListAgentWork, %{})
        for agent <- context.agents, do: assert(detail =~ agent.id)
        {:ok, context}
      end
    end
  end
end
