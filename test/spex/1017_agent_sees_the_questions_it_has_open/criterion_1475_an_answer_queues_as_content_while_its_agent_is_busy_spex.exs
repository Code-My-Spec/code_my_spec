defmodule CodeMySpecSpex.Story1017.Criterion3577Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 3577 — An answer queues as content while its agent is busy.

  The held provider supplies a real in-flight turn. Questions are created
  through MCP and answered through the user-facing form. Task lifecycle
  remains separate from delivering the answer to the conversation.
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

  spex "An answer queues as content while its agent is busy", criterion: 1475 do
    scenario "Answer delivery does not interrupt or resume the blocked task" do
      given_ "a staffed checkout has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_3577_queued_answer")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "the agent has a task-linked question and a running user turn", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Question-dependent work",
            description: "Work awaiting a product decision",
            acceptance_criteria: ["The chosen behavior has a specification"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(story.number)
            },
            frame
          )

        task_id = extract_task_id!(started)

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: task_id,
              questions: [
                %{
                  question: "Which behavior?",
                  options: [%{label: "Keep existing"}, %{label: "Change it"}]
                }
              ]
            },
            frame
          )

        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
        base_url = HeldProvider.start()
        HeldProvider.hold()
        {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)

        {:ok, :started} =
          Machine.send_message(agent.id, "user-turn-3577", "Finish this user turn")

        HeldProvider.await_request()
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)

        {:ok,
         Map.merge(context, %{
           agent_id: agent.id,
           frame: frame,
           task_id: task_id,
           question_id: question_id,
           conversation_path: Fixtures.agent_conversation_path(context.scope, agent)
         })}
      end

      when_ "the user answers the question", context do
        {:ok, view, _} = live(context.conn, "/app/questions/#{context.question_id}")

        view
        |> form("main [data-test='question-form']", %{"q_0" => "Keep existing"})
        |> render_submit()

        {:ok, Map.put(context, :question_view, view)}
      end

      then_ "the answer is saved and queued without a concurrent turn", context do
        assert render(context.question_view) =~ "Answer sent."

        {:reply, answer, _} =
          CheckAnswer.execute(%{question_id: context.question_id}, context.frame)

        refute answer.isError, response_text(answer)
        assert response_text(answer) =~ "Keep existing"
        assert {:ok, %{busy?: true, queued: 1}} = Machine.status(context.agent_id)
        assert length(HeldProvider.seen()) == 1
        {:ok, view, _} = live(context.conn, context.conversation_path)
        assert render(view) =~ "Keep existing"
        assert has_element?(view, "[data-test='toggle-agent-working'][data-working='true']")
        {:ok, context}
      end

      then_ "the task still needs deliberate resumption", context do
        {:reply, tasks, _} = ListTasks.execute(%{}, context.frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[blocked]"
        refute response_text(tasks) =~ "[active]"
        {:ok, context}
      end
    end
  end
end
