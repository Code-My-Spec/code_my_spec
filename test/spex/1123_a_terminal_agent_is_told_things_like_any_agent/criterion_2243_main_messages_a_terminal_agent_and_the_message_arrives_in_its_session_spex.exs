defmodule CodeMySpecSpex.Story1123.Criterion2243Spex do
  @moduledoc """
  Story 1123 — A terminal agent is told things like any agent.
  Criterion 2243 — Main messages a terminal agent and the message arrives in
  its session.
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

  spex "Main's message reaches a terminal agent's session", criterion: 2243 do
    scenario "main messages a terminal agent whose Claude Code accepts cross-session messages" do
      given_ "a terminal agent whose session names its inbox socket", context do
        context = HarnessHooks.ensure_live_harness(context)
        inbox = open_inbox()
        started = start_session_on_socket(context, session_id(), inbox.socket)
        await_present(context, started["agent_id"])
        {:ok, Map.merge(context, %{inbox: inbox, agent_id: started["agent_id"]})}
      end

      when_ "main sends it a message", context do
        sent =
          ToolLibrary.run(
            "message_agent",
            %{"agent_id" => context.agent_id, "message" => "Rebase on main, then carry on."},
            %{scope: context.scope}
          )

        {:ok, Map.put(context, :sent, sent)}
      end

      then_ "the harness writes it to the session's inbox socket, without waiting for a stop",
            context do
        assert {:ok, _} = context.sent

        assert_receive {:inbox,
                        %{
                          "type" => "user",
                          "message" => %{"content" => "Rebase on main, then carry on."}
                        }},
                       5_000

        {:ok, context}
      end
    end
  end
end
