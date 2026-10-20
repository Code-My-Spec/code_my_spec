defmodule CodeMySpecSpex.Story1129.Criterion2292Spex do
  @moduledoc """
  Story 1129 — A terminal Codex agent's state reads like any agent's.
  Criterion 2292 — John reads a Codex agent's conversation like any agent's.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers, only: [set_role: 3]
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

  # A Codex coder whose session is open and whose hooks fire; its rollout is
  # where Codex writes what it says and spends.
  defp a_codex_coder(context) do
    context = HarnessHooks.ensure_live_harness(context)
    session = codex_session_id()
    rollout = codex_rollout_for(session)
    started = start_codex_session(context, session, %{"transcript_path" => rollout})
    assert {:ok, _} = set_role(context, session, "coding")

    Map.merge(context, %{session: session, rollout: rollout, agent_id: started["agent_id"]})
  end

  spex "John reads a Codex agent's conversation like any agent's", criterion: 2292 do
    scenario "the coder works a task and John opens its conversation" do
      given_ "John's terminal Codex coder has worked a task", context do
        context = a_codex_coder(context)
        codex_submit_prompt(context, context.session)

        write_codex_rollout(
          context.rollout,
          codex_called("shell", %{"command" => ["mix", "test"]})
        )

        write_codex_rollout(context.rollout, codex_said("Splitting the reservations context."))
        codex_stop_turn(context, context.session)
        {:ok, context}
      end

      when_ "John opens its conversation", context do
        eventually(fn ->
          {:ok, said} =
            ToolLibrary.run("read_agent_conversation", %{"agent_id" => context.agent_id}, %{
              scope: context.scope
            })

          assert said =~ "Splitting the reservations context."
        end)

        {:ok, said} =
          ToolLibrary.run("read_agent_conversation", %{"agent_id" => context.agent_id}, %{
            scope: context.scope
          })

        {:ok, Map.put(context, :conversation, said)}
      end

      then_ "he sees what it said and the tools it used, replayed from Codex's session files",
            context do
        assert context.conversation =~ "Splitting the reservations context."
        assert context.conversation =~ "shell"
        {:ok, context}
      end
    end
  end
end
