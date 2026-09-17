defmodule CodeMySpecSpex.Story1070.Criterion3541Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3541 — An agent closes its task when the stop hook asks.

  Rule: An agent closes the work it finished.

  The recovery path for 3540. An agent that forgot to close is told, by name
  and by id, on its next landing — `StopDecision` renders the open task into
  the menu precisely so that forgetting is recoverable rather than permanent.
  If the reminder does not work, the reminder is decoration.

  The second half is what makes this measurable at all. An agent that replies
  "yes, that task is done" and calls nothing has answered the person and not
  the harness: the task is still open, the graph still has not moved, and the
  next landing says the same thing again. Answering the menu with prose is the
  shape of that failure, which is why the criterion rules it out explicitly.

  The task is handed to the agent through `start_task` with its id, which is
  how the main agent aims work at one of its agents (`e15d1ff1`). So this also
  exercises the assignment itself: a task that landed on the wrong queue would
  never appear in this agent's menu, and the criterion would fail with the
  agent having done nothing wrong.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers
  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :eval

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent closes the work it finished" do
    scenario "An agent closes its task when the stop hook asks" do
      given_ :synced_context_in_satisfied_project

      given_ "a checkout on the harness, reporting what its agents do", context do
        {:ok, given_a_harnessed_checkout(context, "eval_3541")}
      end

      when_ "an agent holding an open task is woken", context do
        measured =
          measure("An agent closes its task when the stop hook asks", fn _run ->
            observe(context, [role: "coding", wake: false], fn agent ->
              hand_a_task(context, agent)
              wake(context, agent)
              settle(agent)

              called?(context, agent, "evaluate_task")
            end)
          end)

        {:ok, Map.put(context, :measured, measured)}
      end

      then_ "it closes the task the menu named", context do
        assert_rate(context.measured, 0.9)

        {:ok, context}
      end
    end
  end

  # Aimed at this agent rather than started by it, because the premise is an
  # agent that already holds one — `start_task`'s `agent_id` is what puts it on
  # that agent's own queue.
  defp hand_a_task(context, agent_id) do
    {:reply, response, _} =
      StartTask.execute(
        %{
          requirement_name: "tests_passing",
          entity_type: "component",
          entity_id: context.component.id,
          agent_id: agent_id
        },
        frame(context)
      )

    refute response.isError,
           """
           No task was handed to the agent, so the premise — an agent whose stop
           decision names an open task — never held, and this run measures
           nothing.

           #{response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")}
           """

    :ok
  end
end
