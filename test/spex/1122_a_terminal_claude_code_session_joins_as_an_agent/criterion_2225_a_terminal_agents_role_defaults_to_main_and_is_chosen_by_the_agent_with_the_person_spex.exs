defmodule CodeMySpecSpex.Story1122.Criterion2225Spex do
  @moduledoc """
  Story 1122 — A terminal Claude Code session joins as an agent.
  Criterion 2225 — A terminal agent's role defaults to main and is chosen by the agent with the person.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A terminal agent's role defaults to main and is chosen with the person",
    criterion: 2225 do
    scenario "a session joins as main, then takes the role it agreed on" do
      given_ "a terminal session that has just registered", context do
        context = HarnessHooks.ensure_live_harness(context)
        session = session_id()
        {:ok, Map.merge(context, %{session: session, started: start_session(context, session)})}
      end

      then_ "its role is main, and it is told to settle its role with the person", context do
        assert %{"role" => "main"} = agent_for(context, context.started)
        assert context.started["hookSpecificOutput"]["additionalContext"] =~ "ask the person"
        {:ok, context}
      end

      when_ "the person and the agent agree on product and the agent sets it", context do
        {:ok, Map.put(context, :set, set_role(context, context.session, "product"))}
      end

      then_ "the agent's role is product", context do
        assert {:ok, _} = context.set
        assert %{"role" => "product"} = agent_for(context, context.started)
        {:ok, context}
      end
    end
  end
end
