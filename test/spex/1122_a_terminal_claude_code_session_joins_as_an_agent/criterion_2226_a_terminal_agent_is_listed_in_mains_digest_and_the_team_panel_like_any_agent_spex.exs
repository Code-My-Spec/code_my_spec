defmodule CodeMySpecSpex.Story1122.Criterion2226Spex do
  @moduledoc """
  Story 1122 — A terminal Claude Code session joins as an agent.
  Criterion 2226 — A terminal agent is listed in main's digest and the team panel like any agent.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpec.ToolLibrary

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A terminal agent is listed in main's digest and the team panel", criterion: 2226 do
    scenario "main and the person look at the agents" do
      given_ "a registered terminal agent", context do
        context = HarnessHooks.ensure_live_harness(context)
        started = start_session(context, session_id())
        {:ok, Map.put(context, :agent_id, started["agent_id"])}
      end

      when_ "main reads its digest", context do
        {:ok, digest} = ToolLibrary.run("list_agent_work", %{}, %{scope: context.scope})
        {:ok, Map.put(context, :digest, digest)}
      end

      then_ "the terminal agent is listed there with its role", context do
        assert context.digest =~ String.slice(context.agent_id, 0, 8)
        assert context.digest =~ "main"
        {:ok, context}
      end

      when_ "the person opens the copy's team panel", context do
        {:ok, _view, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/working-copies/#{context.scope.active_working_copy_id}"
          )

        {:ok, Map.put(context, :panel, html)}
      end

      then_ "the terminal agent is listed there like any other agent", context do
        assert context.panel =~ String.slice(context.agent_id, 0, 8)
        {:ok, context}
      end
    end
  end
end
