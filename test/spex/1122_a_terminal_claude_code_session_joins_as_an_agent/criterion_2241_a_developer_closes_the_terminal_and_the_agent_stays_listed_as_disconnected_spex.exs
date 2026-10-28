defmodule CodeMySpecSpex.Story1122.Criterion2241Spex do
  @moduledoc """
  Story 1122 — A terminal Claude Code session joins as an agent.
  Criterion 2241 — A developer closes the terminal and the agent stays listed as disconnected.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpec.Agents
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp panel(context) do
    {:ok, _view, html} =
      live(
        context.conn,
        "/app/projects/#{context.project.id}/working-copies/#{context.scope.active_working_copy_id}"
      )

    html
  end

  spex "A developer closing the terminal leaves the agent listed, as not connected",
    criterion: 2241 do
    scenario "a developer closes the terminal a terminal agent runs in" do
      given_ "a terminal agent listed in main's digest, its session live", context do
        context = HarnessHooks.ensure_live_harness(context)
        inbox = open_inbox()
        session = session_id()
        started = start_session_on_socket(context, session, inbox.socket)

        {:ok,
         Map.merge(context, %{inbox: inbox, session: session, agent_id: started["agent_id"]})}
      end

      when_ "the developer closes that terminal", context do
        close_session(context.session, context.inbox)
        look(context.agent_id)
        {:ok, context}
      end

      then_ "the agent stays listed, shown as not connected", context do
        # The panel's status follows the same presence change asynchronously, so
        # it is waited on, not read once after presence drops.
        eventually(fn ->
          refute MapSet.member?(Agents.present_ids(context.scope), context.agent_id)
          assert panel(context) =~ "Away"
        end)

        assert [%{"id" => id}] = agents(context)
        assert id == context.agent_id
        {:ok, context}
      end

      then_ "nothing is handed to it until its session returns", context do
        # User decision: direct messages use native transports, never the Stop-hook inbox.
        {:error, said} =
          ToolLibrary.run(
            "message_agent",
            %{"agent_id" => context.agent_id, "message" => "Pick up story 1123."},
            %{scope: context.scope}
          )

        assert said =~ "Message not sent"
        refute_receive {:inbox, _}, 1_000
        {:ok, context}
      end
    end
  end
end
