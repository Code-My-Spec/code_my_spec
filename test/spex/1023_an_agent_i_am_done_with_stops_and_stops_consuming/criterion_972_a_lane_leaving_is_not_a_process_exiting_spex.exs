defmodule CodeMySpecSpex.Story1023.Criterion972Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 972 — A lane leaving is not a process exiting.

  Rule: A copy's page reads liveness off the process, not off the channel
  that happens to be reporting it.

  The harness channel tracking an agent present is how the page usually knows
  a process is alive — but the channel and the process are two different
  things, and a channel that drops (a reconnect, a network blip) is not the
  same fact as the process underneath it ending. A page that reads "not
  present" as "stopped" tells the operator their agent is gone when it is
  still running and still spending.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The page's liveness survives a channel that drops", criterion: 972 do
    scenario "A lane leaving is not a process exiting" do
      given_ "an agent whose lane has left the harness channel while its process is still alive",
             context do
        agent = Fixtures.running_agent(context.scope)
        start_agent(agent.id, working_copy: agent.working_copy)

        assert running?(agent.id),
               "the premise is a live process; without one the lane leaving proves " <>
                 "nothing about telling the two apart"

        :ok = Fixtures.mark_absent(agent)

        {:ok, context |> Map.put(:agent, agent)}
      end

      when_ "the page reports what is running", context do
        {:ok, view, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{context.scope.active_working_copy_id}"
          )

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "that agent is not described as stopped on the strength of the lane going", context do
        basis =
          context.view
          |> element("[data-agent-id='#{context.agent.id}'] [data-test='agent-liveness-basis']")
          |> render()

        refute basis =~ ~r/stopped|not up|starting|restored/i,
               "the agent's process is still alive and the page describes it as not " <>
                 "running on the strength of its lane leaving the channel. basis: #{basis}"

        {:ok, Map.put(context, :basis, basis)}
      end

      then_ "and the evidence named is the process, not the channel", context do
        assert context.basis =~ ~r/process/i,
               "the basis shown does not name the process as the evidence for what is " <>
                 "running — it should say the process is alive, not that a channel is " <>
                 "(or is not) present. basis: #{context.basis}"

        {:ok, context}
      end
    end
  end
end
