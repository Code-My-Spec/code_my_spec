defmodule CodeMySpecSpex.Story1128.Criterion2289Spex do
  @moduledoc """
  Story 1128 — A terminal Codex agent is told things like any agent.
  Criterion 2289 — An idle Codex agent that is not continuous is not offered work.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers, only: [set_role: 3]
  import CodeMySpecSpex.TerminalCodexHelpers
  import CodeMySpecSpex.OfferHelpers, only: [coding_work_waiting: 1]
  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1]

  alias CodeMySpec.ToolLibrary
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

  spex "An idle Codex agent is offered work only when it is continuous", criterion: 2289 do
    scenario "work is waiting on the team of an idle, not continuous, Codex agent" do
      given_ "a terminal Codex coder, idle and not continuous, with its team's work waiting",
             context do
        context = coding_work_waiting(context)
        fake = install_fake_codex()
        session = codex_session_id()
        started = start_codex_session(context, session)
        {:ok, _} = set_role(context, session, "coding")
        context = put_to_work(context)
        agent_id = started["agent_id"]

        {:ok, _} =
          ToolLibrary.run(
            "set_agent_continuous",
            %{"agent_id" => agent_id, "continuous" => false},
            %{scope: context.scope}
          )

        codex_submit_prompt(context, session)
        eventually(fn -> assert digest(context) =~ "has not finished" end)
        forget_queued(fake)
        {:ok, Map.merge(context, %{fake: fake, session: session, agent_id: agent_id})}
      end

      when_ "its turn ends and the work waiting is offered to the team", context do
        codex_stop_turn(context, context.session)
        eventually(fn -> assert digest(context) =~ "no turn is open" end)
        {:ok, context}
      end

      then_ "nothing is queued into its session", context do
        assert codex_queued(context.fake) == []
        {:ok, context}
      end

      when_ "John makes it continuous", context do
        {:ok, _} =
          ToolLibrary.run(
            "set_agent_continuous",
            %{"agent_id" => context.agent_id, "continuous" => true},
            %{scope: context.scope}
          )

        {:ok, context}
      end

      then_ "the offer is queued into its session", context do
        eventually(fn ->
          assert [%{message: offer}] = codex_queued(context.fake)
          assert offer =~ "Eligible work is available"
        end)

        {:ok, context}
      end
    end
  end
end
