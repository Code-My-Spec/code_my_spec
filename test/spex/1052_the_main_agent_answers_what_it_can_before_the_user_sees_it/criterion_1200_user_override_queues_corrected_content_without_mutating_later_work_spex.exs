defmodule CodeMySpecSpex.Story1052.Criterion3220Spex do
  @moduledoc """
  Correcting an earlier answer must not resolve a newer blocker on the same
  task. The owner resumes and asks again through MCP before the user overrides
  the old answer. An explicit user turn is held to detect interrupting delivery.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpec.McpServers.Tasks.Tools.ListTasks
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A user override preserves audit history and a newer task blocker", criterion: 1200 do
    scenario "Correcting yesterday's answer does not mutate today's blocked work" do
      given_ "the connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3220")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "main answered a task question and its owner resumed before asking a different question",
             context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refund eligibility",
            description: "Refund policy requiring separate decisions",
            acceptance_criteria: ["Refund eligibility is specified"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        main_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}}

        claim = %{
          entity_type: "story",
          entity_id: to_string(story.number),
          requirement_name: "bdd_specs_exist"
        }

        {:reply, started, _} = StartTask.execute(claim, frame)
        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: task_id,
              questions: [
                %{
                  question: "Should refunds older than ninety days be allowed?",
                  options: [%{label: "Allow"}, %{label: "Refuse"}]
                }
              ]
            },
            frame
          )

        refute asked.isError, response_text(asked)
        old_id = Fixtures.question_id_from(response_text(asked))
        earlier_answer = "Allow refunds on working copy #{context.scope.active_working_copy_id}"

        {:reply, answered, _} =
          AnswerNotification.execute(
            %{id: old_id, answer: earlier_answer, basis: "record"},
            main_frame
          )

        refute answered.isError, response_text(answered)
        {:reply, resumed, _} = StartTask.execute(claim, frame)
        refute resumed.isError, response_text(resumed)
        assert extract_task_id!(resumed) == task_id

        {:reply, later, _} =
          AskUserQuestion.execute(
            %{
              task_id: task_id,
              questions: [
                %{
                  question: "Does a receipt need the customer's postal address?",
                  options: [%{label: "Required"}, %{label: "Optional"}]
                }
              ]
            },
            frame
          )

        refute later.isError, response_text(later)
        new_id = Fixtures.question_id_from(response_text(later))
        {:reply, tasks, _} = ListTasks.execute(%{}, frame)
        refute tasks.isError, response_text(tasks)
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)

        assert {:ok, :started} =
                 Machine.send_message(agent.id, "explicit-3220", "Summarize current refund work")

        HeldProvider.await_request()
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(agent.id)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           frame: frame,
           claim: claim,
           task_id: task_id,
           old_id: old_id,
           new_id: new_id,
           earlier_answer: earlier_answer,
           tasks_before: response_text(tasks)
         })}
      end

      when_ "the user reads main's earlier answer and overrides it", context do
        {:ok, view, _} = live(context.conn, "/app/questions/#{context.old_id}")
        assert render(view) =~ context.earlier_answer
        view |> form("main [data-test='question-form']", %{"q_0" => "Refuse"}) |> render_submit()
        assert render(view) =~ "Answer sent."
        {:ok, context}
      end

      then_ "the saved answer identifies the override and retains the earlier answer for audit",
            context do
        {:reply, answer, _} = CheckAnswer.execute(%{question_id: context.old_id}, context.frame)
        refute answer.isError, response_text(answer)
        assert response_text(answer) =~ "Refuse"
        assert response_text(answer) =~ ~r/user.*overrul/i
        {:ok, view, _} = live(context.conn, "/app/questions/#{context.old_id}")
        assert render(view) =~ "Refuse"
        assert render(view) =~ context.earlier_answer
        {:ok, context}
      end

      then_ "the newer blocker and task state are unchanged and no interrupt is queued",
            context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        assert response_text(tasks) =~ "[blocked]"
        assert response_text(tasks) =~ context.task_id
        {:reply, pending, _} = CheckAnswer.execute(%{question_id: context.new_id}, context.frame)
        refute pending.isError, response_text(pending)
        assert response_text(pending) =~ ~r/still waiting/i
        {:reply, refused, _} = StartTask.execute(context.claim, context.frame)
        assert refused.isError, response_text(refused)
        assert response_text(refused) =~ ~r/block|answer/i
        assert {:ok, %{busy?: true, queued: 0}} = Machine.status(context.agent_id)
        [request] = HeldProvider.seen()
        assert request =~ "Summarize current refund work"
        {:ok, context}
      end
    end
  end
end
