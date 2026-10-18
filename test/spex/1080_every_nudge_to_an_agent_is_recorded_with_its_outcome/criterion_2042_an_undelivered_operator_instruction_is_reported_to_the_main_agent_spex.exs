defmodule CodeMySpecSpex.Story1080.Criterion2042Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2042 — An undelivered operator instruction is reported to the
  main agent: named with the agent, the instruction's text and the time
  delivery failed, distinguishable from an agent that received it and
  declined it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [agent_out_of_reach: 1]
  import Phoenix.LiveViewTest

  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "An undelivered operator instruction is reported to main", criterion: 2042 do
    scenario "an operator's message to an unreachable agent is never delivered" do
      given_ "an agent whose machine cannot be reached, and a continuous main", context do
        agent = Fixtures.running_agent(context.scope, role: "coding")
        :ok = agent_out_of_reach(agent)

        {:ok, _} =
          WorkingCopies.designate_main(context.scope, context.scope.active_working_copy_id)

        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, main.id)
        {:ok, Map.merge(context, %{agent_struct: agent, agent: agent.id, main_id: main.id})}
      end

      when_ "an operator sends it an instruction", context do
        {:ok, live, _} =
          live(
            context.conn,
            Fixtures.agent_conversation_path(context.scope, context.agent_struct)
          )

        live
        |> form("[data-test='agent-message-form']", message: "Please stand by.")
        |> render_submit()

        {:ok, context}
      end

      when_ "that agent's turn ends", context do
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.agent)
        :ok = Fixtures.end_turn(context.scope, context.agent)
        {:ok, context}
      end

      then_ "main is told the instruction was never delivered, naming the agent, text and time",
            context do
        main_id = context.main_id
        agent_id = context.agent

        assert_receive {:agent_dispatch, ^main_id, _ref, notice}, 2_000
        assert notice =~ "coding agent #{agent_id}", notice
        assert notice =~ "was never delivered", notice
        assert notice =~ "Please stand by.", notice
        {:ok, Map.put(context, :notice, notice)}
      end

      then_ "that is distinguishable from an agent that received it and declined it", context do
        refute context.notice =~ "declined", context.notice
        refute context.notice =~ "Reason:", context.notice
        {:ok, context}
      end
    end
  end
end
