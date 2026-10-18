defmodule CodeMySpecSpex.Story1123.Criterion2245Spex do
  @moduledoc """
  Story 1123 — A terminal agent is told things like any agent.
  Criterion 2245 — A terminal agent mid-turn reads a message between tool calls, and send-now says it will not interrupt.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A terminal agent mid-turn is not interrupted, and send-now says so", criterion: 2245 do
    scenario "main sends a message now to a terminal agent in the middle of a turn" do
      given_ "a terminal agent in the middle of a turn", context do
        context = HarnessHooks.ensure_live_harness(context)
        inbox = open_inbox()
        session = session_id()
        started = start_session_on_socket(context, session, inbox.socket)
        session_is(session, "busy")
        look(started["agent_id"])

        eventually(fn ->
          {:ok, work} = ToolLibrary.run("list_agent_work", %{}, %{scope: context.scope})
          assert work =~ "has not finished"
        end)

        {:ok, Map.merge(context, %{inbox: inbox, agent_id: started["agent_id"]})}
      end

      when_ "main sends it a message with send-now", context do
        sent =
          ToolLibrary.run(
            "message_agent",
            %{
              "agent_id" => context.agent_id,
              "message" => "Stop and rebase.",
              "send_now" => true
            },
            %{scope: context.scope}
          )

        {:ok, Map.put(context, :sent, sent)}
      end

      then_ "the sender is told it will not interrupt the turn", context do
        assert {:ok, said} = context.sent
        assert said =~ "next tool call"
        assert said =~ "cannot be interrupted"
        {:ok, context}
      end

      then_ "the message goes to the session, which reads it between tool calls", context do
        assert_receive {:inbox, %{"message" => %{"content" => "Stop and rebase."}}}, 5_000
        {:ok, context}
      end
    end
  end
end
