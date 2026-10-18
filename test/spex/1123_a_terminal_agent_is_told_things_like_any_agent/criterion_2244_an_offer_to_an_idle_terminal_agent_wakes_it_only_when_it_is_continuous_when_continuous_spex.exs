defmodule CodeMySpecSpex.Story1123.Criterion2244ContinuousSpex do
  @moduledoc """
  Story 1123 — A terminal agent is told things like any agent.
  Criterion 2244 — An offer to an idle terminal agent wakes it only when it is
  continuous.

  The offer is the one a turn ending makes when work is waiting: the moment a
  terminal agent goes idle is when the loop offers it its next piece.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers
  import CodeMySpecSpex.OfferHelpers, only: [coding_work_waiting: 1]
  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1]

  alias CodeMySpec.ToolLibrary

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An offer to an idle continuous terminal agent wakes it", criterion: 2244 do
    scenario "a terminal coder's turn ends with coding work waiting" do
      given_ "an idle terminal coder, continuous, on a working copy with coding work waiting",
             context do
        {:ok, busy_terminal_coder(context, true)}
      end

      when_ "its turn ends, and the work waiting is offered", context do
        session_is(context.session, "idle")
        look(context.agent_id)
        {:ok, context}
      end

      then_ "it is woken in its session to act on the work", context do
        assert_receive {:inbox, %{"type" => "user", "message" => %{"content" => offer}}}, 5_000
        assert offer =~ "Eligible work is available"
        {:ok, context}
      end
    end
  end

  # On a working copy (its loop on, which offers and makes its agents
  # continuous), set continuous or not, and in the middle of a turn.
  defp busy_terminal_coder(context, continuous?) do
    context = coding_work_waiting(context)
    inbox = open_inbox()
    session = session_id()
    started = start_session_on_socket(context, session, inbox.socket)
    {:ok, _} = set_role(context, session, "coding")
    context = put_to_work(context)
    agent_id = started["agent_id"]

    {:ok, _} =
      ToolLibrary.run(
        "set_agent_continuous",
        %{"agent_id" => agent_id, "continuous" => continuous?},
        %{scope: context.scope}
      )

    session_is(session, "busy")
    look(agent_id)

    eventually(fn ->
      {:ok, work} = ToolLibrary.run("list_agent_work", %{}, %{scope: context.scope})
      assert work =~ "has not finished"
    end)

    flush_inbox()
    Map.merge(context, %{inbox: inbox, session: session, agent_id: agent_id})
  end

  defp flush_inbox do
    receive do
      {:inbox, _} -> flush_inbox()
    after
      500 -> :ok
    end
  end
end
