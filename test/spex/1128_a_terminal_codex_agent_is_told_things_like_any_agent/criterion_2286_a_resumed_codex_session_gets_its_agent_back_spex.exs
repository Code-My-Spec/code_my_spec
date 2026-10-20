defmodule CodeMySpecSpex.Story1128.Criterion2286Spex do
  @moduledoc """
  Story 1128 — A terminal Codex agent is told things like any agent.
  Criterion 2286 — A resumed Codex session gets its agent back.
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

  spex "A resumed Codex session gets its agent back", criterion: 2286 do
    scenario "John resumes a Codex session that joined and was closed" do
      given_ "John's Codex session joined as an agent and was closed", context do
        context = HarnessHooks.ensure_live_harness(context)
        session = codex_session_id()
        started = start_codex_session(context, session)
        assert {:ok, _} = set_role(context, session, "qa")
        codex_hook(context, "session-end", session)
        {:ok, Map.merge(context, %{session: session, started: started})}
      end

      when_ "John resumes that Codex session", context do
        resumed = start_codex_session(context, context.session, %{"source" => "resume"})
        {:ok, Map.put(context, :resumed, resumed)}
      end

      then_ "it is the same agent, not a new one", context do
        assert context.resumed["agent_id"] == context.started["agent_id"]
        assert [%{"role" => "qa", "engine" => "codex"}] = agents(context)
        {:ok, context}
      end
    end
  end
end
