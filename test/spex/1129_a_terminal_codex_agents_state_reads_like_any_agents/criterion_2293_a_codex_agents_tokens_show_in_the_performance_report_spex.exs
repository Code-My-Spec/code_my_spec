defmodule CodeMySpecSpex.Story1129.Criterion2293Spex do
  @moduledoc """
  Story 1129 — A terminal Codex agent's state reads like any agent's.
  Criterion 2293 — A Codex agent's tokens show in the performance report.
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

  defp digest(context) do
    {:ok, work} = ToolLibrary.run("list_agent_work", %{}, %{scope: context.scope})
    work
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

  defp turn(context, input, output, text) do
    codex_submit_prompt(context, context.session)
    eventually(fn -> assert digest(context) =~ "has not finished" end)
    write_codex_rollout(context.rollout, codex_turn_context("gpt-5-codex"))
    write_codex_rollout(context.rollout, codex_said(text))
    write_codex_rollout(context.rollout, codex_spent(input, output))
    codex_stop_turn(context, context.session)
    eventually(fn -> assert digest(context) =~ "no turn is open" end)
  end

  spex "A Codex agent's tokens show in the performance report", criterion: 2293 do
    scenario "the coder finishes two turns and John reads the report" do
      given_ "John's terminal Codex coder finished two turns", context do
        context = a_codex_coder(context)
        turn(context, 1200, 340, "First turn done.")
        turn(context, 800, 200, "Second turn done.")
        {:ok, context}
      end

      when_ "John reads the agent performance report", context do
        {:ok, Map.put(context, :report_for, context.agent_id)}
      end

      then_ "the coder's tokens for its turns appear there, from Codex's session files",
            context do
        eventually(fn ->
          {:ok, report} =
            ToolLibrary.run("agent_performance_report", %{"agent_id" => context.report_for}, %{
              scope: context.scope
            })

          # 1,200 in and 340 out, then 800 in and 200 out: 2,540 across the two.
          assert report =~ ~r/codex \|.*\| 2540 \|/
        end)

        {:ok, context}
      end
    end
  end
end
