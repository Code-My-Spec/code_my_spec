defmodule CodeMySpecSpex.Story1128.Criterion2287Spex do
  @moduledoc """
  Story 1128 — A terminal Codex agent is told things like any agent.
  Criterion 2287 — Main messages a terminal Codex agent and the message is queued into its session.
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

  defp message(context, text, extra \\ %{}) do
    ToolLibrary.run(
      "message_agent",
      Map.merge(%{"agent_id" => context.agent_id, "message" => text}, extra),
      %{scope: context.scope}
    )
  end

  spex "Main's message is queued into a Codex session with codex queue", criterion: 2287 do
    scenario "main messages a terminal Codex agent" do
      given_ "a terminal Codex agent on the copy", context do
        context = HarnessHooks.ensure_live_harness(context)
        fake = install_fake_codex()
        session = codex_session_id()
        started = start_codex_session(context, session)

        {:ok, Map.merge(context, %{fake: fake, session: session, agent_id: started["agent_id"]})}
      end

      when_ "main messages it", context do
        {:ok, Map.put(context, :sent, message(context, "Rebase on main, then carry on."))}
      end

      then_ "the message is queued into its Codex session with codex queue", context do
        eventually(fn ->
          assert [%{thread: thread, message: "Rebase on main, then carry on."}] =
                   codex_queued(context.fake)

          assert thread == context.session
        end)

        {:ok, context}
      end

      then_ "main is told it was delivered", context do
        assert {:ok, said} = context.sent
        assert said =~ "delivered"
        {:ok, context}
      end
    end
  end
end
