defmodule CodeMySpecSpex.Story1052.Criterion3223Spex do
  @moduledoc """
  An offline answer is durable data, not a command to start an engine.
  Explicitly restarting the same agent preserves its task, answer and policy;
  only an explicit claim resumes the answered attempt.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.HarnessLifecycleHelpers, only: [given_a_staffed_checkout: 2]
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CmsHarnessTest.HeldProvider
  alias CmsHarnessTest.Machine
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

  spex "An answer survives an explicit restart without starting the agent itself",
    criterion: 1203 do
    scenario "The same continuous agent reads its saved answer and deliberately resumes" do
      given_ "the connected project has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3223")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a continuous agent asked a task question and its engine was then stopped",
             context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Receipt format after restart",
            description: "A task with a durable unanswered decision",
            acceptance_criteria: ["The receipt format is specified"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        claim = %{
          entity_type: "story",
          entity_id: to_string(story.number),
          requirement_name: "bdd_specs_exist"
        }

        {:reply, started, _} = StartTask.execute(claim, frame)
        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)

        # The graph pass the fixtures above queued, done now instead of in two
        # seconds. `GraphWatcher` debounces, and the moment the question below
        # blocks this task the agent becomes runnable — so a pass landing in
        # that window admits a turn, the provider records it, and this
        # criterion's "nothing started the engine" reads as a product failure.
        # On a quiet box the pass lands earlier, while the task is still
        # active and the agent is not runnable, which is why it passed alone
        # and failed in a suite.
        :ok = Fixtures.settle_graph(context.scope)

        base_url = HeldProvider.start()
        HeldProvider.hold()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: task_id,
              questions: [
                %{
                  question: "Should receipts include the tax breakdown?",
                  options: [%{label: "Include tax breakdown"}, %{label: "Total only"}]
                }
              ]
            },
            frame
          )

        refute asked.isError, response_text(asked)
        question_id = Fixtures.question_id_from(response_text(asked))
        assert :ok = Machine.stop_agent(agent.id)
        assert {:error, :not_running} = Machine.status(agent.id)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           frame: frame,
           claim: claim,
           task_id: task_id,
           question_id: question_id,
           base_url: base_url,
           stopped_registry: Machine.running(),
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the user answers while the engine is stopped", context do
        {:ok, view, _} = live(context.conn, "/app/questions/#{context.question_id}")

        view
        |> form("main [data-test='question-form']", %{"q_0" => "Include tax breakdown"})
        |> render_submit()

        assert render(view) =~ "Answer sent."
        {:ok, context}
      end

      then_ "answer submission neither starts the engine nor clears continuous intent", context do
        assert {:error, :not_running} = Machine.status(context.agent_id)
        assert Machine.running() == context.stopped_registry
        assert HeldProvider.seen() == []
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      when_ "the operator explicitly restarts that same durable agent", context do
        assert {:ok, _} =
                 Machine.start_agent(context.agent_id, context.copy, base_url: context.base_url)

        {:ok, context}
      end

      then_ "the saved answer and its author survive while the linked task remains blocked",
            context do
        {:reply, answer, _} =
          CheckAnswer.execute(%{question_id: context.question_id}, context.frame)

        refute answer.isError, response_text(answer)
        assert response_text(answer) =~ "Include tax breakdown"
        assert response_text(answer) =~ ~r/user replied/i
        {:reply, tasks, _} = ListTasks.execute(%{}, context.frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[blocked]"
        assert response_text(tasks) =~ context.question_id
        refute response_text(tasks) =~ "[active]"
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      when_ "the agent explicitly resumes the answered requirement", context do
        {:reply, resumed, _} = StartTask.execute(context.claim, context.frame)
        refute resumed.isError, response_text(resumed)
        assert extract_task_id!(resumed) == context.task_id
        {:ok, context}
      end

      then_ "the original task alone is active", context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[active]"
        refute response_text(tasks) =~ "[blocked]"
        {:ok, context}
      end
    end
  end
end
