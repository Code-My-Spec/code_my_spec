defmodule CodeMySpecSpex.Story1053.Criterion3269Spex do
  @moduledoc """
  A nested answer is not an answer to the original question. Once main answers
  the original, its task still needs explicit resumption; a neighboring task's
  unanswered blocker is unaffected throughout the chain.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion
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

  spex "Answering a question chain resolves only the original task's blocker", criterion: 1239 do
    scenario "Main answers after the user, then coding explicitly resumes its own attempt" do
      given_ "the connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3269")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "two coding agents have independently claimed and questioned their tasks", context do
        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)
        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(main.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(main.id) end)

        tasks =
          Enum.map(["Deployment target", "Receipt retention"], fn title ->
            story =
              StoryHelpers.create_and_link(context.scope, context.component.module_name,
                title: title,
                description: "Independent work with its own unresolved question",
                acceptance_criteria: ["The behavior has a specification"]
              )

            :ok =
              ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
                persona_id: context.persona_id
              )

            agent = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
            frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
            assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
            on_exit(fn -> Machine.stop_agent(agent.id) end)

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
                      question: "Which #{title} policy should I implement?",
                      options: [%{label: "Existing"}, %{label: "New"}]
                    }
                  ]
                },
                frame
              )

            refute asked.isError, response_text(asked)

            %{
              id: task_id,
              question_id: Fixtures.question_id_from(response_text(asked)),
              frame: frame,
              agent_id: agent.id,
              claim: claim
            }
          end)

        [original, neighbor] = tasks

        {:ok,
         Map.merge(context, %{
           original: original,
           neighbor: neighbor,
           main_id: main.id,
           main_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}},
           running_ids: Machine.running()
         })}
      end

      when_ "main relays the original decision to the user and the user answers it", context do
        {:reply, nested, _} =
          AskUserQuestion.execute(
            %{
              questions: [
                %{
                  question: "Which Deployment target policy should I implement?",
                  options: [%{label: "Existing"}, %{label: "New"}]
                }
              ]
            },
            context.main_frame
          )

        refute nested.isError, response_text(nested)
        nested_id = Fixtures.question_id_from(response_text(nested))

        {:reply, escalated, _} =
          EscalateQuestion.execute(
            %{question_id: nested_id, reason: "The deployment policy is the user's decision"},
            context.main_frame
          )

        refute escalated.isError, response_text(escalated)
        {:ok, view, _} = live(context.conn, "/app/questions/#{nested_id}")

        view
        |> form("main [data-test='question-form']", %{"q_0" => "Existing"})
        |> render_submit()

        assert render(view) =~ "Answer sent."
        {:reply, answer, _} = CheckAnswer.execute(%{question_id: nested_id}, context.main_frame)
        refute answer.isError, response_text(answer)
        assert response_text(answer) =~ "Existing"
        {:ok, Map.put(context, :nested_id, nested_id)}
      end

      then_ "the original still awaits main rather than inheriting the nested answer", context do
        {:reply, pending, _} =
          CheckAnswer.execute(
            %{question_id: context.original.question_id},
            context.original.frame
          )

        refute pending.isError, response_text(pending)
        assert response_text(pending) =~ ~r/still waiting on the main agent/i
        {:ok, context}
      end

      when_ "main explicitly answers the original using the user's decision", context do
        {:reply, answered, _} =
          AnswerNotification.execute(
            %{
              notification_id: context.original.question_id,
              answer: "Use the existing deployment policy",
              basis: "precedent",
              precedent_id: context.nested_id
            },
            context.main_frame
          )

        refute answered.isError, response_text(answered)
        {:ok, context}
      end

      then_ "both tasks remain blocked and no answer or escalation has started a turn", context do
        {:reply, answer, _} =
          CheckAnswer.execute(
            %{question_id: context.original.question_id},
            context.original.frame
          )

        refute answer.isError, response_text(answer)
        assert response_text(answer) =~ "Use the existing deployment policy"

        for task <- [context.original, context.neighbor] do
          {:reply, blocked, _} = ListTasks.execute(%{}, task.frame)
          refute blocked.isError, response_text(blocked)
          assert response_text(blocked) =~ task.id
          assert response_text(blocked) =~ "[blocked]"
          refute response_text(blocked) =~ "[active]"
          assert {:ok, %{busy?: false}} = Machine.status(task.agent_id)
        end

        assert {:ok, %{busy?: false}} = Machine.status(context.main_id)
        assert HeldProvider.seen() == []
        assert Machine.running() == context.running_ids
        {:ok, context}
      end

      when_ "the unanswered neighbor tries to resume before coding resumes the answered task",
            context do
        {:reply, refused, _} = StartTask.execute(context.neighbor.claim, context.neighbor.frame)
        assert refused.isError, response_text(refused)
        assert response_text(refused) =~ ~r/block|answer/i
        {:reply, resumed, _} = StartTask.execute(context.original.claim, context.original.frame)
        refute resumed.isError, response_text(resumed)
        assert extract_task_id!(resumed) == context.original.id
        {:ok, context}
      end

      then_ "only the explicitly resumed task is active", context do
        {:reply, active, _} = ListTasks.execute(%{status: "active"}, context.original.frame)
        refute active.isError, response_text(active)
        assert response_text(active) =~ context.original.id
        {:reply, blocked, _} = ListTasks.execute(%{status: "blocked"}, context.neighbor.frame)
        refute blocked.isError, response_text(blocked)
        assert response_text(blocked) =~ context.neighbor.id
        {:ok, context}
      end
    end
  end
end
