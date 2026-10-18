defmodule CodeMySpecSpex.Story1080.Criterion1868Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1868 — Told its blocker cleared while its task's requirement is
  still waiting on something, an agent does not start the task, and says
  what it is waiting on.

  `Work.wake_released/6`'s own comment: "A released task whose requirement
  still waits on something is not offered: 'resume it' would send the agent
  to `start_task` for a task it is refused. It is told what the task waits
  on instead." `waiting_notice/3` is the real text this asserts on.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.QuestionRoutingHelpers, only: [user_answers: 3]
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.AddDependency
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
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

  spex "A released task still blocked on its graph is not resumed, and says what it waits on",
       criterion: 1868 do
    scenario "a new, unmet dependency is added while the task is blocked on a question" do
      given_ "a coder started an implementation task, actionable, and blocked it on a question",
             context do
        context = FullSatisfactionFixtures.apply_up_to_analysis(context)
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              module_name: context.component.module_name
            },
            frame
          )

        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: task_id,
              questions: [%{"question" => "Which way?", "options" => [%{"label" => "Left"}]}]
            },
            frame
          )

        refute asked.isError, response_text(asked)
        blocker = Fixtures.question_id_from(response_text(asked))
        {:ok, Map.merge(context, %{coder: coder.id, task_id: task_id, blocker: blocker})}
      end

      given_ "the component is given a new, unmet dependency", context do
        other = CodeMySpec.ComponentsFixtures.component_fixture(context.scope)

        {:reply, added, _} =
          AddDependency.execute(
            %{
              module_name: context.component.module_name,
              depends_on_module_name: other.module_name
            },
            %Frame{assigns: %{current_scope: context.scope}}
          )

        refute added.isError, response_text(added)
        {:ok, context}
      end

      when_ "the question that blocked the task is answered", context do
        :ok = user_answers(context, context.blocker, "Left")
        id = context.coder
        assert_receive {:work_turn_requested, ^id, _ref, notice}, 2_000
        {:ok, Map.put(context, :notice, notice)}
      end

      then_ "the agent is not told to start_task on it", context do
        refute context.notice =~ "start_task", context.notice
        {:ok, context}
      end

      then_ "and is told it is not ready to resume, with what it is still waiting on", context do
        assert context.notice =~ "is not ready to resume", context.notice
        assert context.notice =~ "Do not start it yet", context.notice
        assert context.notice =~ "it is offered to you when it opens", context.notice
        {:ok, context}
      end
    end
  end
end
