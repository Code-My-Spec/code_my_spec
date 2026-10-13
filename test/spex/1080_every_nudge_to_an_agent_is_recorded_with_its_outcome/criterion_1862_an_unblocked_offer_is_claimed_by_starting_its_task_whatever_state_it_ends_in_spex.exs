defmodule CodeMySpecSpex.Story1080.Criterion1862Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1862 — An unblocked offer is claimed when the agent starts that
  task after the offer, whatever state the task is in when the turn ends.

  Offers 0a87d287 and d4bd1e9d: the QA agent resumed within seconds, worked the
  task, and was scored as ignoring the offer because the task had moved on by
  turn end.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers, only: [start_agent_task: 3]
  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "Resuming claims the unblocked offer even if the task stops again", criterion: 1862 do
    scenario "the coder resumes, then blocks the task again before its turn ends" do
      given_ "a coder whose blocking question was answered, mid-turn", context do
        context = coder_holding_a_task(context)

        params = %{
          questions: [%{"question" => "Which way?", "options" => [%{"label" => "Left"}]}]
        }

        {:reply, reply, _} = AskUserQuestion.execute(params, agent_frame(context, context.coder))
        refute reply.isError, response_text(reply)
        :ok = user_answers(context, Fixtures.question_id_from(response_text(reply)), "Left")
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, context}
      end

      when_ "it resumes the task, taps out of it again, and ends its turn", context do
        :ok =
          Fixtures.agent_tool_call(context.scope, %{id: context.coder}, "s1", "start_task", %{
            "requirement_name" => context.task.requirement_name,
            "entity_type" => context.task.entity_type,
            "entity_id" => context.task.entity_id
          })

        context = start_agent_task(context, context.coder, context.task)

        {:reply, tapped, _} =
          TapOut.execute(
            %{task_id: context.task_id, reason: "Stuck again."},
            agent_frame(context, context.coder)
          )

        refute tapped.isError, response_text(tapped)
        :ok = Fixtures.end_turn(context.scope, context.coder)
        {:ok, context}
      end

      then_ "the unblocked offer is claimed", context do
        standing =
          context
          |> offers(context.coder, %{kind: "unblocked"})
          |> Enum.reject(&(&1.status == "superseded"))

        assert [%{status: "claimed"}] = standing, listing(context)
        {:ok, context}
      end
    end
  end
end
