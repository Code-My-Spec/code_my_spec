defmodule CodeMySpecSpex.Story1023.Criterion973Spex do
  @moduledoc """
  Story 1023 — An agent I am done with stops, and stops consuming.
  Criterion 973 — The pid survives long enough to be used.

  Rule: The handle to a process is cleared only once something has confirmed
  that process is actually gone.

  A stop that cannot reach the machine has not ended anything, so clearing
  the pid there would throw away the only thing a second attempt could act
  on — the same defect criterion 971 names from the operator's side of the
  same failure.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.TurnOffAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A pid is cleared only once the process behind it is confirmed gone", criterion: 973 do
    scenario "The pid survives long enough to be used" do
      given_ "a running agent whose os_pid is recorded", context do
        agent = Fixtures.running_agent(context.scope)
        agent = Fixtures.record_os_pid(agent, 4242)
        start_agent(agent.id, working_copy: agent.working_copy)
        machine_out_of_reach(context.scope)

        {:ok, context |> Map.put(:agent, agent)}
      end

      when_ "a stop is asked for and the process does not end", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, reply, _frame} = TurnOffAgent.execute(%{"agent_id" => context.agent.id}, frame)

        assert reply.isError,
               "the machine could not be reached, which is the premise — a stop that " <>
                 "succeeded anyway asserts nothing about a pid surviving one that failed"

        {:ok, context}
      end

      then_ "the os_pid is still recorded", context do
        {:ok, _view, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{context.scope.active_working_copy_id}"
          )

        assert html =~ "4242",
               "the pid was cleared by a stop that never confirmed the process was gone " <>
                 "— the one handle anything could have used to reach it is now thrown away"

        {:ok, context}
      end

      then_ "and a second attempt has something to act on", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, second, _frame} = TurnOffAgent.execute(%{"agent_id" => context.agent.id}, frame)

        assert second.isError,
               "a second attempt against the same unreachable machine reported success — " <>
                 "with the pid gone, nothing distinguishes that from an agent that never " <>
                 "had one"

        {:ok, context}
      end
    end
  end
end
