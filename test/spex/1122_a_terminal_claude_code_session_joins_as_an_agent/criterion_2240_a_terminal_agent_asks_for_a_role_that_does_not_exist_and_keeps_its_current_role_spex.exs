defmodule CodeMySpecSpex.Story1122.Criterion2240Spex do
  @moduledoc """
  Story 1122 — A terminal Claude Code session joins as an agent.
  Criterion 2240 — A terminal agent asks for a role that does not exist and keeps its current role.
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

  spex "A terminal agent asking for a role that does not exist keeps its own", criterion: 2240 do
    scenario "a terminal agent sets its role to something that is not a role" do
      given_ "a terminal agent whose role is main", context do
        context = HarnessHooks.ensure_live_harness(context)
        session = session_id()
        {:ok, Map.merge(context, %{session: session, started: start_session(context, session)})}
      end

      when_ "it sets its role to reviewer", context do
        {:ok, Map.put(context, :set, set_role(context, context.session, "reviewer"))}
      end

      then_ "the change is refused naming the valid roles, and it is still main", context do
        assert {:error, refusal} = context.set
        for role <- ~w(main coding qa product), do: assert(refusal =~ role)
        assert %{"role" => "main"} = agent_for(context, context.started)
        {:ok, context}
      end
    end
  end
end
