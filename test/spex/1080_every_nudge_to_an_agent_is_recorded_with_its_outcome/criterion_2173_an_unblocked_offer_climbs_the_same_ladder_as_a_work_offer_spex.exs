defmodule CodeMySpecSpex.Story1080.Criterion2173Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2173 — An unblocked offer climbs the same ladder as a work
  offer: id, then detail, then adjacent tasks.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.IdleAgentHelpers, only: [put_to_work: 1, start_session: 1]
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "An unblocked offer's rungs climb from id, to detail, to alternatives", criterion: 2173 do
    scenario "a coder ignores its released task three turns running" do
      given_ "a coder blocked its first task on a question and took the other", context do
        context =
          context
          |> coding_work_waiting()
          |> FullSatisfactionFixtures.apply_two_components_to_implement()
          |> start_session()
          |> put_to_work()

        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        frame = agent_frame(context, coder.id)

        first = ToolLibrary.run("start_task", next_task(context, coder.id), tool_context(frame))
        assert match?({:ok, _}, first), response_text(first)

        reply =
          ToolLibrary.run(
            "ask_user_question",
            %{
              task_id: extract_task_id!(first),
              questions: [%{"question" => "Which way?", "options" => [%{"label" => "Left"}]}]
            },
            tool_context(frame)
          )

        assert match?({:ok, _}, reply), response_text(reply)

        other = ToolLibrary.run("start_task", next_task(context, coder.id), tool_context(frame))
        assert match?({:ok, _}, other), response_text(other)

        {:ok,
         Map.merge(context, %{
           coder: coder.id,
           task_id: extract_task_id!(first),
           other_task_id: extract_task_id!(other),
           blocker: Fixtures.question_id_from(response_text(reply))
         })}
      end

      # Busy on the other task when the answer lands, it is told, not pushed
      # (John, 2026-10-18: no preemption); setting that task down frees it.
      when_ "the question is answered, and it sets the other task down", context do
        id = context.coder
        :ok = discard_pushes(id)
        :ok = user_answers(context, context.blocker, "Left")

        cancelled =
          ToolLibrary.run(
            "cancel_task",
            %{task_id: context.other_task_id},
            tool_context(agent_frame(context, id))
          )

        assert match?({:ok, _}, cancelled), response_text(cancelled)
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:work_turn_requested, ^id, _ref, first}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, Map.put(context, :first, first)}
      end

      then_ "the first rung names the task by its id", context do
        assert context.first =~ context.task_id, context.first
        {:ok, context}
      end

      when_ "it ends the turn without resuming, and is offered again", context do
        id = context.coder
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:work_turn_requested, ^id, _ref, second}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        {:ok, Map.put(context, :second, second)}
      end

      then_ "the next rung sends the task's detail", context do
        assert context.second =~ "Why it matters:", context.second
        {:ok, context}
      end

      when_ "it ignores that too, and is offered a third time", context do
        id = context.coder
        :ok = Fixtures.end_turn(context.scope, id)
        assert_receive {:work_turn_requested, ^id, _ref, third}, 2_000
        {:ok, Map.put(context, :third, third)}
      end

      then_ "the next rung also names adjacent tasks it could take instead", context do
        assert context.third =~ "Other work you could take instead:", context.third
        {:ok, context}
      end
    end
  end

  # Pushes made while the given_ set the agent up, before the one under test.
  defp discard_pushes(id) do
    receive do
      {:work_turn_requested, ^id, _ref, _prompt} -> discard_pushes(id)
    after
      0 -> :ok
    end
  end

  # A tool runs from a frame's assigns, with the scope under the key ToolLibrary reads.
  defp tool_context(%{assigns: assigns}), do: Map.put(assigns, :scope, assigns[:current_scope])
end
