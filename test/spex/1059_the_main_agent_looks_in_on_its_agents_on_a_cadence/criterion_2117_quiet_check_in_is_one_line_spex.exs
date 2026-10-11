defmodule CodeMySpecSpex.Story1059.Criterion2117Spex do
  @moduledoc "A quiet check-in is one line without a model turn"
  use CodeMySpecSpex.Case
  alias CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation
  alias CodeMySpecSpex.CompactCadenceHelpers, as: Compact
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A quiet check-in is one line without a model turn", criterion: 2117 do
    scenario "A quiet check-in is one line without a model turn" do
      given_ "an existing quiet agent has no role work", context do
        context = Compact.fleet(context, 1)
        [agent] = context.agents
        assert Fixtures.role_queue_size(context.scope, agent.id) == 0
        before = Compact.call(context, ReadAgentConversation, %{agent_id: agent.id})
        {:ok, Map.put(context, :before, before)}
      end

      when_ "main asks for a check-in", context do
        {:ok, Compact.report(context)}
      end

      then_ "the report stays on one line and the conversation is unchanged", context do
        assert length(String.split(String.trim(context.report), "\n")) == 1
        assert context.report =~ "Nothing needs you"
        [agent] = context.agents

        assert Compact.call(context, ReadAgentConversation, %{agent_id: agent.id}) ==
                 context.before

        refute_received {:work_turn_requested, _, _, _}
        {:ok, context}
      end
    end
  end
end
