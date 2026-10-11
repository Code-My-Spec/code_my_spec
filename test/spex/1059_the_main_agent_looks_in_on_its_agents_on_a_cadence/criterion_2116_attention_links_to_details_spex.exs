defmodule CodeMySpecSpex.Story1059.Criterion2116Spex do
  @moduledoc "Attention items name a valid detail call instead of inventing an answer"
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

  spex "Attention items name a valid detail call instead of inventing an answer",
    criterion: 2116 do
    scenario "Attention items name a valid detail call instead of inventing an answer" do
      given_ "one existing agent has reported repeated turn timeouts", context do
        context = Compact.fleet(context, 1)
        [agent] = context.agents
        :ok = Fixtures.fail_turn(context.scope, agent.id, "claude exec timed out after 180000ms")
        {:ok, Map.put(context, :attention, agent)}
      end

      when_ "main asks for a check-in", context do
        {:ok, Compact.report(context)}
      end

      then_ "the exact suggested arguments retrieve the reported evidence", context do
        assert context.report =~ "Needs you:"

        assert context.report =~
                 ~s|read_agent_conversation({agent_id = "#{context.attention.id}", limit = 5})|

        refute context.report =~ "answer_notification"

        detail =
          Compact.call(context, ReadAgentConversation, %{agent_id: context.attention.id, limit: 5})

        assert detail =~ "timed out"
        {:ok, context}
      end
    end
  end
end
