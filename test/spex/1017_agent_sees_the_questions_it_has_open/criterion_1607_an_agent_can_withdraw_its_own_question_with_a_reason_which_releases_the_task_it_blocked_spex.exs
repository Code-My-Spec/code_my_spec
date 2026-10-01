defmodule CodeMySpecSpex.Story1017.Criterion1607Spex do
  @moduledoc """
  Story 1017 — Agent sees the questions it has open.
  Criterion 1607 — An agent can withdraw its own question with a reason, which
  releases the task it blocked.

  8c91d5bc: a coder blocked a customer's fix on its own question, which went
  moot minutes later (product rewrote the criterion), and it had no way to
  take the question back. The fix sat off main for 20+ minutes.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.McpServers.Tasks.Tools.WithdrawQuestion
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent can withdraw its own question with a reason, which releases the task it blocked",
    criterion: 1607 do
    scenario "A coder's question goes moot and it takes it back" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coder holding a story's task, blocked on its own question", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refund policy",
            description: "A story whose criterion was in doubt",
            acceptance_criteria: ["The stated behavior is specified"]
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

        refute started.isError, response_text(started)
        task_id = extract_task_id!(started)

        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: task_id,
              questions: [
                %{
                  question: "Revert criterion 944 or rewrite it?",
                  options: [%{label: "Revert"}, %{label: "Rewrite"}]
                }
              ]
            },
            frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))

        {:ok,
         Map.merge(context, %{
           frame: frame,
           story: story,
           task_id: task_id,
           question_id: question_id
         })}
      end

      when_ "the coder withdraws the question, saying why", context do
        {:reply, withdrawn, _} =
          WithdrawQuestion.execute(
            %{question_id: context.question_id, reason: "product rewrote criterion 944"},
            context.frame
          )

        {:ok, Map.put(context, :withdrawn, withdrawn)}
      end

      then_ "the withdrawal is accepted and names the task to pick back up", context do
        refute context.withdrawn.isError, response_text(context.withdrawn)
        assert response_text(context.withdrawn) =~ context.task_id
        {:ok, context}
      end

      then_ "and the question says it was withdrawn, and why", context do
        {:reply, checked, _} =
          CheckAnswer.execute(%{question_id: context.question_id}, context.frame)

        text = response_text(checked)

        assert text =~ "withdrew"
        assert text =~ "product rewrote criterion 944"
        {:ok, context}
      end

      then_ "and the task it blocked can be resumed", context do
        {:reply, resumed, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(context.story.number)
            },
            context.frame
          )

        refute resumed.isError,
               "the task stayed blocked on a question its asker withdrew: #{response_text(resumed)}"

        {:ok, context}
      end
    end
  end
end
