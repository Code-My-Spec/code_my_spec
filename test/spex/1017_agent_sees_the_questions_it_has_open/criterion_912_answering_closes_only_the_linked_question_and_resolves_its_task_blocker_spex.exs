defmodule CodeMySpecSpex.Story1017.Criterion2419Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 2419 — An answer resolves only its matching task blocker.

  Two questions are created through MCP. Answer one through the UI and inspect
  both durable tasks before any resume. Explicit claims then distinguish the
  resolved blocker from its still-unanswered neighbor without reading the DB.
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

  spex "Answering one question resolves only the task that asked it", criterion: 912 do
    scenario "The answered task can be explicitly resumed while its neighbor remains blocked" do
      given_ "a connected checkout has completed kickoff", context do
        context = given_a_staffed_checkout(context, "spex_2419")
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a durable coding agent has asked about two independently claimed stories",
             context do
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        base_url = HeldProvider.start()
        assert {:ok, _} = Machine.start_agent(agent.id, context.copy, base_url: base_url)
        on_exit(fn -> Machine.stop_agent(agent.id) end)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}

        questions =
          Enum.map(["Refund period", "Receipt format"], fn title ->
            story =
              StoryHelpers.create_and_link(context.scope, context.component.module_name,
                title: title,
                description: "Independent work with a durable unanswered decision",
                acceptance_criteria: ["The chosen behavior is specified"]
              )

            :ok =
              ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
                persona_id: context.persona_id
              )

            started =
              ToolLibrary.run(
                "start_task",
                %{
                  requirement_name: "bdd_specs_exist",
                  entity_type: "story",
                  entity_id: to_string(story.number)
                },
                Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
              )

            assert match?({:ok, _}, started), response_text(started)
            task_id = extract_task_id!(started)

            asked =
              ToolLibrary.run(
                "ask_question",
                %{
                  task_id: task_id,
                  questions: [
                    %{
                      question: "Which #{title} should we use?",
                      options: [%{label: "Keep existing"}, %{label: "Change it"}]
                    }
                  ]
                },
                Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
              )

            assert match?({:ok, _}, asked), response_text(asked)
            [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))

            %{
              id: question_id,
              task_id: task_id,
              story_id: story.id,
              story_number: story.number,
              text: "Which #{title} should we use?"
            }
          end)

        {:ok, Map.merge(context, %{agent_id: agent.id, frame: frame, questions: questions})}
      end

      when_ "the user answers the first question", context do
        [first, _second] = context.questions
        {:ok, view, _} = live(context.conn, "/app/questions/#{first.id}")

        view
        |> form("main [data-test='question-form']", %{"q_0" => "Keep existing"})
        |> render_submit()

        assert render(view) =~ "Answer sent."
        {:ok, context}
      end

      then_ "only the answered question closes and both task attempts remain blocked", context do
        [first, second] = context.questions

        answer =
          ToolLibrary.run(
            "check_answer",
            %{question_id: first.id},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, answer), response_text(answer)
        assert response_text(answer) =~ "Keep existing"

        pending =
          ToolLibrary.run(
            "check_answer",
            %{question_id: second.id},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, pending), response_text(pending)
        assert response_text(pending) =~ "Still waiting"

        tasks =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, tasks), response_text(tasks)
        text = response_text(tasks)
        assert text =~ "# Tasks (2)"
        assert length(Regex.scan(~r/\[blocked\]/, text)) == 2
        refute text =~ "[active]"
        assert text =~ first.task_id
        assert text =~ second.task_id

        questions =
          ToolLibrary.run(
            "list_user_questions",
            %{},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, questions), response_text(questions)
        assert response_text(questions) =~ "1 open question"
        assert response_text(questions) =~ second.id
        refute response_text(questions) =~ first.id

        assert :ok = Machine.await_idle(context.agent_id)
        assert HeldProvider.seen() == []
        {:ok, context}
      end

      when_ "the agent tries to resume the task whose question remains unanswered", context do
        [_first, second] = context.questions

        refused =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(second.story_number)
            },
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:error, _}, refused), response_text(refused)
        assert response_text(refused) =~ ~r/block|answer/i
        {:ok, context}
      end

      then_ "the answered task alone can be deliberately resumed using its original task id",
            context do
        [first, second] = context.questions

        resumed =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(first.story_number)
            },
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, resumed), response_text(resumed)
        assert extract_task_id!(resumed) == first.task_id

        active =
          ToolLibrary.run(
            "list_tasks",
            %{status: "active"},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, active), response_text(active)
        assert response_text(active) =~ "# Tasks (1)"
        assert response_text(active) =~ first.task_id
        refute response_text(active) =~ second.task_id

        all =
          ToolLibrary.run(
            "list_tasks",
            %{},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, all), response_text(all)
        assert response_text(all) =~ "# Tasks (2)"
        assert response_text(all) =~ second.task_id
        assert length(Regex.scan(~r/\[blocked\]/, response_text(all))) == 1
        {:ok, context}
      end
    end
  end
end
