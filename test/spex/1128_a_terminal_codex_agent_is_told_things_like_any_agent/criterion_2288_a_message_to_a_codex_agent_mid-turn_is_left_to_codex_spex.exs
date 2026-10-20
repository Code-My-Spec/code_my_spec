defmodule CodeMySpecSpex.Story1128.Criterion2288Spex do
  @moduledoc """
  Story 1128 — A terminal Codex agent is told things like any agent.
  Criterion 2288 — A message to a Codex agent mid-turn is left to Codex.
  """
  use CodeMySpecSpex.Case

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

  defp digest(context) do
    {:ok, work} = ToolLibrary.run("list_agent_work", %{}, %{scope: context.scope})
    work
  end

  defp message(context, text, extra) do
    ToolLibrary.run(
      "message_agent",
      Map.merge(%{"agent_id" => context.agent_id, "message" => text}, extra),
      %{scope: context.scope}
    )
  end

  spex "A message to a Codex agent mid-turn is queued and left to Codex", criterion: 2288 do
    scenario "main messages a terminal Codex agent in the middle of a turn" do
      given_ "a terminal Codex agent on the copy", context do
        context = HarnessHooks.ensure_live_harness(context)
        fake = install_fake_codex()
        session = codex_session_id()
        started = start_codex_session(context, session)

        {:ok, Map.merge(context, %{fake: fake, session: session, agent_id: started["agent_id"]})}
      end

      given_ "the agent is mid-turn", context do
        codex_submit_prompt(context, context.session)
        eventually(fn -> assert digest(context) =~ "has not finished" end)
        {:ok, context}
      end

      when_ "main messages it", context do
        {:ok,
         Map.put(context, :sent, message(context, "Stop and rebase.", %{"send_now" => true}))}
      end

      then_ "the message is queued without stopping the turn", context do
        assert {:ok, _} = context.sent

        eventually(fn ->
          assert [%{message: "Stop and rebase."}] = codex_queued(context.fake)
        end)

        assert digest(context) =~ "has not finished"
        {:ok, context}
      end

      then_ "Codex reads it when Codex chooses: the sender is told it will not interrupt",
            context do
        assert {:ok, said} = context.sent
        assert said =~ "cannot be interrupted"
        {:ok, context}
      end
    end
  end
end
