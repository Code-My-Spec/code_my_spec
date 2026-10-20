defmodule CodeMySpecSpex.Story1128.Criterion2285Spex do
  @moduledoc """
  Story 1128 — A terminal Codex agent is told things like any agent.
  Criterion 2285 — John starts Codex in a team checkout and it joins as an agent.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers, only: [agents: 1, set_role: 3]
  import CodeMySpecSpex.TerminalCodexHelpers

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "John starts Codex in a team checkout and it joins as an agent", criterion: 2285 do
    scenario "a Codex session opens in the checkout the harness serves" do
      given_ "team 4's checkout is served by the harness", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      when_ "John starts a Codex session in it", context do
        session = codex_session_id()

        {:ok,
         Map.merge(context, %{session: session, started: start_codex_session(context, session)})}
      end

      then_ "a Codex agent appears on the copy, keyed on that session's id", context do
        assert agent_id = context.started["agent_id"]
        assert [%{"id" => ^agent_id, "engine" => "codex"}] = agents(context)

        again = start_codex_session(context, context.session)
        assert again["agent_id"] == agent_id
        {:ok, context}
      end

      then_ "it starts as main until it chooses its role with John", context do
        assert [%{"role" => "main"}] = agents(context)
        assert {:ok, _} = set_role(context, context.session, "coding")
        assert [%{"role" => "coding"}] = agents(context)
        {:ok, context}
      end
    end
  end
end
