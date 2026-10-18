defmodule CodeMySpecSpex.Story1122.Criterion2238Spex do
  @moduledoc """
  Story 1122 — A terminal Claude Code session joins as an agent.
  Criterion 2238 — A session id already registered on another project is not adopted here.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A session id registered on another project is not adopted here", criterion: 2238 do
    scenario "the same Claude Code session id starts on a checkout of a second project" do
      given_ "a session id registered as an agent on project A", context do
        context = HarnessHooks.ensure_live_harness(context)
        session = session_id()
        on_a = start_session(context, session)
        {:ok, Map.merge(context, %{session: session, on_a: on_a})}
      end

      when_ "a session with that id starts on a checkout of project B", context do
        b_scope =
          Fixtures.other_project_scope(
            context.scope,
            "project-b-#{System.unique_integer([:positive])}"
          )

        b =
          HarnessHooks.ensure_live_harness(
            context
            |> Map.drop([:harness])
            |> Map.merge(%{scope: b_scope, project: b_scope.active_project})
          )

        {:ok, Map.merge(context, %{b: b, on_b: start_session(b, context.session)})}
      end

      then_ "project B registers its own agent, and project A's is untouched", context do
        refute context.on_b["agent_id"] == context.on_a["agent_id"]
        assert [%{"id" => b_id}] = agents(context.b)
        assert b_id == context.on_b["agent_id"]
        assert [%{"id" => a_id, "role" => "main"}] = agents(context)
        assert a_id == context.on_a["agent_id"]
        {:ok, context}
      end
    end
  end
end
