defmodule CodeMySpecSpex.Story1122.Criterion2222Spex do
  @moduledoc """
  Story 1122 — A terminal Claude Code session joins as an agent.
  Criterion 2222 — A resumed session gets its existing agent back, not a new one.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A resumed session gets its existing agent back, not a new one", criterion: 2222 do
    scenario "a developer resumes a session that registered and then ended" do
      given_ "a terminal session that registered, took the qa role, and then ended", context do
        context = HarnessHooks.ensure_live_harness(context)
        session = session_id()
        started = start_session(context, session)
        assert {:ok, _} = set_role(context, session, "qa")
        {:ok, Map.merge(context, %{session: session, started: started})}
      end

      when_ "the developer resumes that Claude Code session", context do
        {:ok,
         Map.put(
           context,
           :resumed,
           start_session(context, context.session, %{"source" => "resume"})
         )}
      end

      then_ "the existing agent is returned, with its role, not a new one", context do
        assert context.resumed["agent_id"] == context.started["agent_id"]
        assert [%{"role" => "qa"}] = agents(context)
        {:ok, context}
      end
    end
  end
end
