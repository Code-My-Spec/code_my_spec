defmodule CodeMySpecSpex.Story1017.Criterion3579Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 3579 — Resuming an answered task is an explicit revalidated claim.

  Three independent cases distinguish a valid resume, a withdrawn requirement,
  and another agent's claim. Every task and answer is created through MCP/UI.
  Resumption must preserve the stable task UUID and recheck current eligibility
  and ownership rather than treating an answer as permission to activate work.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Stories.Tools.UpdateStory
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

  spex "Explicit resume revalidates eligible work" do
    scenario "The claim respects the answered task's current eligibility and owner" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coding agent owns a task whose question has been answered", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Resume contract eligible",
            description: "A story whose question must be resolved before an explicit resume",
            acceptance_criteria: ["The chosen behavior has a specification"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        {:reply, graph, _} = GetNextRequirement.execute(%{}, frame)
        refute graph.isError, response_text(graph)

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(story.id)
            },
            frame
          )

        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: task_id,
              questions: [
                %{
                  question: "Which behavior should I implement?",
                  options: [%{label: "Keep existing"}, %{label: "Change it"}]
                }
              ]
            },
            frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
        {:ok, view, _} = live(context.conn, "/app/questions/#{question_id}")

        view
        |> form("main [data-test='question-form']", %{"q_0" => "Keep existing"})
        |> render_submit()

        assert render(view) =~ "Answer sent."
        {:reply, answer, _} = CheckAnswer.execute(%{question_id: question_id}, frame)
        refute answer.isError, response_text(answer)
        assert response_text(answer) =~ "Keep existing"
        {:reply, tasks, _} = ListTasks.execute(%{}, frame)
        refute tasks.isError, response_text(tasks)

        {:ok,
         Map.merge(context, %{
           frame: frame,
           story_id: story.id,
           task_id: task_id,
           question_id: question_id,
           tasks_before: response_text(tasks)
         })}
      end

      when_ "start_task explicitly requests the answered requirement", context do
        {:reply, result, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(context.story_id)
            },
            context.frame
          )

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the result preserves task identity and respects the current eligible condition",
            context do
        refute context.result.isError, response_text(context.result)
        assert extract_task_id!(context.result) == context.task_id
        assert context.tasks_before =~ "[blocked]"
        refute context.tasks_before =~ "[active]"
        {:reply, tasks, _} = ListTasks.execute(%{}, context.frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) =~ "# Tasks (1)"
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[active]"
        refute response_text(tasks) =~ "[blocked]"

        {:reply, answer, _} =
          CheckAnswer.execute(%{question_id: context.question_id}, context.frame)

        refute answer.isError, response_text(answer)
        assert response_text(answer) =~ "Keep existing"
        {:ok, context}
      end
    end
  end

  spex "Explicit resume revalidates withdrawn work" do
    scenario "The claim respects the answered task's current eligibility and owner" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coding agent owns a task whose question has been answered", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Resume contract withdrawn",
            description: "A story whose question must be resolved before an explicit resume",
            acceptance_criteria: ["The chosen behavior has a specification"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        {:reply, graph, _} = GetNextRequirement.execute(%{}, frame)
        refute graph.isError, response_text(graph)

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(story.id)
            },
            frame
          )

        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: task_id,
              questions: [
                %{
                  question: "Which behavior should I implement?",
                  options: [%{label: "Keep existing"}, %{label: "Change it"}]
                }
              ]
            },
            frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
        {:ok, view, _} = live(context.conn, "/app/questions/#{question_id}")

        view
        |> form("main [data-test='question-form']", %{"q_0" => "Keep existing"})
        |> render_submit()

        assert render(view) =~ "Answer sent."
        {:reply, answer, _} = CheckAnswer.execute(%{question_id: question_id}, frame)
        refute answer.isError, response_text(answer)
        assert response_text(answer) =~ "Keep existing"
        {:reply, tasks, _} = ListTasks.execute(%{}, frame)
        refute tasks.isError, response_text(tasks)

        {:ok,
         Map.merge(context, %{
           frame: frame,
           story_id: story.id,
           task_id: task_id,
           question_id: question_id,
           tasks_before: response_text(tasks)
         })}
      end

      given_ "the story has been withdrawn from development after the answer", context do
        {:reply, updated, _} =
          UpdateStory.execute(
            %{story_id: to_string(context.story_id), ready_for_dev: false},
            context.frame
          )

        refute updated.isError, response_text(updated)
        {:reply, graph, _} = GetNextRequirement.execute(%{}, context.frame)
        refute graph.isError, response_text(graph)
        {:ok, context}
      end

      when_ "start_task explicitly requests the answered requirement", context do
        {:reply, result, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(context.story_id)
            },
            context.frame
          )

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the result preserves task identity and respects the current withdrawn condition",
            context do
        assert context.result.isError, response_text(context.result)
        {:reply, tasks, _} = ListTasks.execute(%{}, context.frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == context.tasks_before
        assert response_text(tasks) =~ context.task_id
        assert response_text(tasks) =~ "[blocked]"
        refute response_text(tasks) =~ "[active]"

        {:reply, answer, _} =
          CheckAnswer.execute(%{question_id: context.question_id}, context.frame)

        refute answer.isError, response_text(answer)
        assert response_text(answer) =~ "Keep existing"
        {:ok, context}
      end
    end
  end

  spex "Explicit resume revalidates foreign_owner work" do
    scenario "The claim respects the answered task's current eligibility and owner" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coding agent owns a task whose question has been answered", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Resume contract foreign_owner",
            description: "A story whose question must be resolved before an explicit resume",
            acceptance_criteria: ["The chosen behavior has a specification"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
        {:reply, graph, _} = GetNextRequirement.execute(%{}, frame)
        refute graph.isError, response_text(graph)

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(story.id)
            },
            frame
          )

        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: task_id,
              questions: [
                %{
                  question: "Which behavior should I implement?",
                  options: [%{label: "Keep existing"}, %{label: "Change it"}]
                }
              ]
            },
            frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
        {:ok, view, _} = live(context.conn, "/app/questions/#{question_id}")

        view
        |> form("main [data-test='question-form']", %{"q_0" => "Keep existing"})
        |> render_submit()

        assert render(view) =~ "Answer sent."
        {:reply, answer, _} = CheckAnswer.execute(%{question_id: question_id}, frame)
        refute answer.isError, response_text(answer)
        assert response_text(answer) =~ "Keep existing"
        {:reply, tasks, _} = ListTasks.execute(%{}, frame)
        refute tasks.isError, response_text(tasks)

        {:ok,
         Map.merge(context, %{
           frame: frame,
           story_id: story.id,
           task_id: task_id,
           question_id: question_id,
           tasks_before: response_text(tasks)
         })}
      end

      given_ "another coding agent attempts to take the answered task", context do
        other = Fixtures.running_agent(context.scope, role: "coding", continuous: false)
        other_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: other.id}}
        {:reply, tasks, _} = ListTasks.execute(%{}, other_frame)
        refute tasks.isError, response_text(tasks)
        assert response_text(tasks) == "No tasks."
        {:ok, Map.put(context, :other_frame, other_frame)}
      end

      when_ "start_task explicitly requests the answered requirement", context do
        {:reply, result, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(context.story_id)
            },
            context.other_frame
          )

        {:ok, Map.put(context, :result, result)}
      end

      then_ "the result preserves task identity and respects the current foreign_owner condition",
            context do
        assert context.result.isError, response_text(context.result)
        {:reply, other_tasks, _} = ListTasks.execute(%{}, context.other_frame)
        refute other_tasks.isError, response_text(other_tasks)
        assert response_text(other_tasks) == "No tasks."
        {:reply, owner_tasks, _} = ListTasks.execute(%{}, context.frame)
        refute owner_tasks.isError, response_text(owner_tasks)
        assert response_text(owner_tasks) == context.tasks_before
        assert response_text(owner_tasks) =~ context.task_id
        assert response_text(owner_tasks) =~ "[blocked]"

        {:reply, answer, _} =
          CheckAnswer.execute(%{question_id: context.question_id}, context.frame)

        refute answer.isError, response_text(answer)
        assert response_text(answer) =~ "Keep existing"
        {:ok, context}
      end
    end
  end
end
