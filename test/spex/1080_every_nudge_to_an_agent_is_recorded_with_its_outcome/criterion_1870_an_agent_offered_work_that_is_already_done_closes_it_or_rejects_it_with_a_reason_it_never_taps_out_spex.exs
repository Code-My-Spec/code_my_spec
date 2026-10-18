defmodule CodeMySpecSpex.Story1080.Criterion1870Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1870 — An agent offered work that is already done closes it or
  rejects it with a reason; it never taps out or leaves it open.

  `StartTask`'s `not_already_done/3`: when the requirement is found already
  satisfied, the system itself calls `Offers.close_stale/2` (status:
  declined, reason: "already satisfied") -- its own comment: "the system
  knows the offer is stale, so it does not wait for the agent to say so."
  The agent never has to call `reject_offer` or `tap_out` for this to happen.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Already-done work closes its own offer, without reject_offer or tap_out",
       criterion: 1870 do
    scenario "a second agent finishes the offered work first" do
      given_ "a coder is offered work it has not yet claimed", context do
        context = offered_work(context)
        {:ok, Map.put(context, :work, next_task(context, context.coder))}
      end

      given_ "a second agent claims and finishes that same work first", context do
        other = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        other_work = next_task(context, other.id)
        context = start_agent_task(context, other.id, other_work)
        task_id = held_task_id(context, other.id)

        {:reply, evaluated, _} =
          EvaluateTask.execute(%{task_id: task_id}, agent_frame(context, other.id))

        refute evaluated.isError, response_text(evaluated)
        {:ok, context}
      end

      when_ "the originally offered coder calls start_task on that same, now-finished work",
            context do
        {:reply, result, _} = StartTask.execute(context.work, agent_frame(context, context.coder))
        {:ok, Map.put(context, :result, result)}
      end

      then_ "it is refused, told the work is already satisfied and its offer is closed",
            context do
        assert context.result.isError, response_text(context.result)
        assert response_text(context.result) =~ "already satisfied", response_text(context.result)

        assert response_text(context.result) =~ "the offer of it is closed",
               response_text(context.result)

        {:ok, context}
      end

      then_ "the offer settles declined with that reason, not left open", context do
        assert [%{status: "declined", reason: "already satisfied"}] =
                 offers(context, context.coder, %{kind: "work"}),
               listing(context)

        {:ok, context}
      end
    end
  end
end
