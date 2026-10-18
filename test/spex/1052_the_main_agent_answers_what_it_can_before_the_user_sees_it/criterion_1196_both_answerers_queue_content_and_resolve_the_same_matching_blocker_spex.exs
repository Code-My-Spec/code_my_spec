defmodule CodeMySpecSpex.Story1052.Criterion3216Spex do
  @moduledoc """
  User and main-agent answers share the durable blocker contract. Each route
  answers one of two independent task questions. Only its task can later resume,
  and neither answer is delivered as a control-message turn.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
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

  spex "A user answer resolves only its matching blocker", criterion: 1196 do
    scenario "The saved answer needs no wake, and resumption remains explicit" do
      given_ "the connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3216_user")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "two agents have task-linked questions and idle continuous-off engines", context do
        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)
        answer = "Working copy #{context.scope.active_working_copy_id}"

        tasks =
          Enum.map(["Export specification", "Receipt specification"], fn title ->
            story =
              StoryHelpers.create_and_link(context.scope, context.component.module_name,
                title: title,
                description: "Independent task with a question",
                acceptance_criteria: ["The behavior is specified"]
              )

            :ok =
              ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
                persona_id: context.persona_id
              )

            agent = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
            frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

            claim = %{
              entity_type: "story",
              entity_id: to_string(story.number),
              requirement_name: "bdd_specs_exist"
            }

            started =
              ToolLibrary.run(
                "start_task",
                claim,
                Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
              )

            assert match?({:ok, _}, started), response_text(started)
            task_id = extract_task_id!(started)

            asked =
              ToolLibrary.run(
                "ask_user_question",
                %{
                  task_id: task_id,
                  questions: [
                    %{
                      question: "Which working copy owns #{title}?",
                      options: [%{label: answer}, %{label: "Another checkout"}]
                    }
                  ]
                },
                Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
              )

            assert match?({:ok, _}, asked), response_text(asked)

            %{
              id: task_id,
              question_id: Fixtures.question_id_from(response_text(asked)),
              frame: frame,
              agent_id: agent.id,
              claim: claim
            }
          end)

        base_url = HeldProvider.start()
        HeldProvider.hold()

        for task <- tasks do
          assert {:ok, _} = Machine.start_agent(task.agent_id, context.copy, base_url: base_url)
          on_exit(fn -> Machine.stop_agent(task.agent_id) end)
          assert {:ok, %{busy?: false}} = Machine.status(task.agent_id)
        end

        [original, neighbor] = tasks

        {:ok,
         Map.merge(context, %{
           original: original,
           neighbor: neighbor,
           answer: answer,
           main_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}},
           running_ids: Machine.running()
         })}
      end

      when_ "the user answers the original question through its supported surface", context do
        {:ok, view, _} = live(context.conn, "/app/questions/#{context.original.question_id}")

        view
        |> form("main [data-test='question-form']", %{"q_0" => context.answer})
        |> render_submit()

        assert render(view) =~ "Answer sent."

        {:ok, context}
      end

      then_ "the answer is readable and both attempts remain blocked without a wake turn",
            context do
        answer =
          ToolLibrary.run(
            "check_answer",
            %{question_id: context.original.question_id},
            Map.put(
              context.original.frame.assigns,
              :scope,
              context.original.frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, answer), response_text(answer)
        assert response_text(answer) =~ context.answer

        for task <- [context.original, context.neighbor] do
          tasks =
            ToolLibrary.run(
              "list_tasks",
              %{},
              Map.put(task.frame.assigns, :scope, task.frame.assigns[:current_scope])
            )

          assert match?({:ok, _}, tasks), response_text(tasks)
          assert response_text(tasks) =~ task.id
          assert response_text(tasks) =~ "[blocked]"
          refute response_text(tasks) =~ "[active]"
          assert {:ok, %{busy?: false}} = Machine.status(task.agent_id)
        end

        assert HeldProvider.seen() == []
        assert Machine.running() == context.running_ids
        {:ok, context}
      end

      when_ "each owner deliberately attempts to resume", context do
        refused =
          ToolLibrary.run(
            "start_task",
            context.neighbor.claim,
            Map.put(
              context.neighbor.frame.assigns,
              :scope,
              context.neighbor.frame.assigns[:current_scope]
            )
          )

        assert match?({:error, _}, refused), response_text(refused)
        assert response_text(refused) =~ ~r/block|answer/i

        resumed =
          ToolLibrary.run(
            "start_task",
            context.original.claim,
            Map.put(
              context.original.frame.assigns,
              :scope,
              context.original.frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, resumed), response_text(resumed)
        assert extract_task_id!(resumed) == context.original.id
        {:ok, context}
      end

      then_ "only the answered attempt becomes active, with the same UUID", context do
        active =
          ToolLibrary.run(
            "list_tasks",
            %{status: "active"},
            Map.put(
              context.original.frame.assigns,
              :scope,
              context.original.frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, active), response_text(active)
        assert response_text(active) =~ context.original.id

        blocked =
          ToolLibrary.run(
            "list_tasks",
            %{status: "blocked"},
            Map.put(
              context.neighbor.frame.assigns,
              :scope,
              context.neighbor.frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, blocked), response_text(blocked)
        assert response_text(blocked) =~ context.neighbor.id
        {:ok, context}
      end
    end
  end

  spex "A main agent answer resolves only its matching blocker" do
    scenario "The saved answer needs no wake, and resumption remains explicit" do
      given_ "the connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3216_main_agent")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "two agents have task-linked questions and idle continuous-off engines", context do
        main = Fixtures.running_agent(context.scope, role: "main", continuous: false)
        answer = "Working copy #{context.scope.active_working_copy_id}"

        tasks =
          Enum.map(["Export specification", "Receipt specification"], fn title ->
            story =
              StoryHelpers.create_and_link(context.scope, context.component.module_name,
                title: title,
                description: "Independent task with a question",
                acceptance_criteria: ["The behavior is specified"]
              )

            :ok =
              ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
                persona_id: context.persona_id
              )

            agent = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
            frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

            claim = %{
              entity_type: "story",
              entity_id: to_string(story.number),
              requirement_name: "bdd_specs_exist"
            }

            started =
              ToolLibrary.run(
                "start_task",
                claim,
                Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
              )

            assert match?({:ok, _}, started), response_text(started)
            task_id = extract_task_id!(started)

            asked =
              ToolLibrary.run(
                "ask_user_question",
                %{
                  task_id: task_id,
                  questions: [
                    %{
                      question: "Which working copy owns #{title}?",
                      options: [%{label: answer}, %{label: "Another checkout"}]
                    }
                  ]
                },
                Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
              )

            assert match?({:ok, _}, asked), response_text(asked)

            %{
              id: task_id,
              question_id: Fixtures.question_id_from(response_text(asked)),
              frame: frame,
              agent_id: agent.id,
              claim: claim
            }
          end)

        base_url = HeldProvider.start()
        HeldProvider.hold()

        for task <- tasks do
          assert {:ok, _} = Machine.start_agent(task.agent_id, context.copy, base_url: base_url)
          on_exit(fn -> Machine.stop_agent(task.agent_id) end)
          assert {:ok, %{busy?: false}} = Machine.status(task.agent_id)
        end

        [original, neighbor] = tasks

        {:ok,
         Map.merge(context, %{
           original: original,
           neighbor: neighbor,
           answer: answer,
           main_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}},
           running_ids: Machine.running()
         })}
      end

      when_ "the main agent answers the original question through its supported surface",
            context do
        answered =
          ToolLibrary.run(
            "answer_notification",
            %{
              notification_id: context.original.question_id,
              answer: context.answer,
              basis: "record"
            },
            Map.put(
              context.main_frame.assigns,
              :scope,
              context.main_frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, answered), response_text(answered)

        {:ok, context}
      end

      then_ "the answer is readable and both attempts remain blocked without a wake turn",
            context do
        answer =
          ToolLibrary.run(
            "check_answer",
            %{question_id: context.original.question_id},
            Map.put(
              context.original.frame.assigns,
              :scope,
              context.original.frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, answer), response_text(answer)
        assert response_text(answer) =~ context.answer

        for task <- [context.original, context.neighbor] do
          tasks =
            ToolLibrary.run(
              "list_tasks",
              %{},
              Map.put(task.frame.assigns, :scope, task.frame.assigns[:current_scope])
            )

          assert match?({:ok, _}, tasks), response_text(tasks)
          assert response_text(tasks) =~ task.id
          assert response_text(tasks) =~ "[blocked]"
          refute response_text(tasks) =~ "[active]"
          assert {:ok, %{busy?: false}} = Machine.status(task.agent_id)
        end

        assert HeldProvider.seen() == []
        assert Machine.running() == context.running_ids
        {:ok, context}
      end

      when_ "each owner deliberately attempts to resume", context do
        refused =
          ToolLibrary.run(
            "start_task",
            context.neighbor.claim,
            Map.put(
              context.neighbor.frame.assigns,
              :scope,
              context.neighbor.frame.assigns[:current_scope]
            )
          )

        assert match?({:error, _}, refused), response_text(refused)
        assert response_text(refused) =~ ~r/block|answer/i

        resumed =
          ToolLibrary.run(
            "start_task",
            context.original.claim,
            Map.put(
              context.original.frame.assigns,
              :scope,
              context.original.frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, resumed), response_text(resumed)
        assert extract_task_id!(resumed) == context.original.id
        {:ok, context}
      end

      then_ "only the answered attempt becomes active, with the same UUID", context do
        active =
          ToolLibrary.run(
            "list_tasks",
            %{status: "active"},
            Map.put(
              context.original.frame.assigns,
              :scope,
              context.original.frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, active), response_text(active)
        assert response_text(active) =~ context.original.id

        blocked =
          ToolLibrary.run(
            "list_tasks",
            %{status: "blocked"},
            Map.put(
              context.neighbor.frame.assigns,
              :scope,
              context.neighbor.frame.assigns[:current_scope]
            )
          )

        assert match?({:ok, _}, blocked), response_text(blocked)
        assert response_text(blocked) =~ context.neighbor.id
        {:ok, context}
      end
    end
  end
end
