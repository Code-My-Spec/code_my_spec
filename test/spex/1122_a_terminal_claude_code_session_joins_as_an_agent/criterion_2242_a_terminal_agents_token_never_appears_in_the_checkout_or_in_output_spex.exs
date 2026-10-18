defmodule CodeMySpecSpex.Story1122.Criterion2242Spex do
  @moduledoc """
  Story 1122 — A terminal Claude Code session joins as an agent.
  Criterion 2242 — A terminal agent's token never appears in the checkout or in output.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp digest(context) do
    {:ok, work} = ToolLibrary.run("list_agent_work", %{}, %{scope: context.scope})
    work
  end

  spex "A terminal agent's token never appears in the checkout or in output", criterion: 2242 do
    scenario "a session that named its inbox socket is reached through it" do
      given_ "a terminal agent reached through its session's inbox socket", context do
        context = HarnessHooks.ensure_live_harness(context)
        inbox = open_inbox()
        session = session_id()
        started = start_session_on_socket(context, session, inbox.socket)

        {:ok,
         Map.merge(context, %{inbox: inbox, session: session, agent_id: started["agent_id"]})}
      end

      when_ "it is sent a message", context do
        {:ok, _} =
          ToolLibrary.run(
            "message_agent",
            %{"agent_id" => context.agent_id, "message" => "Hello."},
            %{scope: context.scope}
          )

        assert_receive {:inbox, %{"message" => %{"content" => "Hello."}}}, 5_000
        {:ok, context}
      end

      then_ "no file in the checkout, and nothing the server answers, names its socket or a token",
            context do
        files = Path.wildcard(Path.join(context.harness.root, "**/*"), match_dot: true)
        refute Enum.any?(files, &(File.regular?(&1) and File.read!(&1) =~ context.inbox.socket))

        for text <- [Jason.encode!(agents(context)), digest(context)] do
          refute text =~ context.inbox.socket
          refute text =~ "peerToken"
        end

        {:ok, context}
      end
    end
  end
end
