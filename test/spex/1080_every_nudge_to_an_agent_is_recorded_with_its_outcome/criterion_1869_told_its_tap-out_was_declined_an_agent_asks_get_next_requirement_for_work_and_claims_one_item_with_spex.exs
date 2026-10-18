defmodule CodeMySpecSpex.Story1080.Criterion1869Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1869 — Told its tap-out was declined, an agent asks
  get_next_requirement for work and claims one item with start_task.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [frame: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
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

  spex "A denied tap-out is followed by get_next_requirement and start_task", criterion: 1869 do
    scenario "a coder's whole-agent tap-out is denied" do
      given_ "a coder offered work asked to leave the loop, and main denied it", context do
        context = offered_work(context)

        {:reply, reply, _} =
          TapOut.execute(%{reason: "Nothing for me here."}, agent_frame(context, context.coder))

        refute reply.isError, response_text(reply)
        [_, request_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(reply))

        # Having asked to leave, its turn ends; main answers while it is idle.
        :ok = Fixtures.end_turn(context.scope, context.coder)

        {:reply, denied, _} =
          AnswerNotification.execute(
            %{notification_id: request_id, decision: "deny", answer: "There is work: take it."},
            frame(context)
          )

        refute denied.isError, response_text(denied)
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, notice}, 2_000
        {:ok, Map.put(context, :notice, notice)}
      end

      when_ "the agent asks get_next_requirement and claims one item", context do
        {:reply, next, _} =
          GetNextRequirement.execute(%{}, agent_frame(context, context.coder))

        refute next.isError, response_text(next)
        [_, name] = Regex.run(~r/^- (\w+) \(/m, response_text(next))

        {:reply, started, _} =
          StartTask.execute(
            %{requirement_name: name, entity_type: "story", entity_id: to_string(context.story.number)},
            agent_frame(context, context.coder)
          )

        {:ok, Map.put(context, :started, started)}
      end

      then_ "the claim succeeds", context do
        refute context.started.isError, response_text(context.started)
        {:ok, context}
      end
    end
  end
end
