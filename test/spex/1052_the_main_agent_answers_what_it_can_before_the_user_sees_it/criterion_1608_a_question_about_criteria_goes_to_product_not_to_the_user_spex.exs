defmodule CodeMySpecSpex.Story1052.Criterion1608Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 1608 — A question about criteria goes to product, not to the user.

  8c91d5bc: the user is now a customer, and a coder's question about a
  criterion's wording is product's to answer — product owns the criteria. The
  asker says so (`about: "criteria"`); no text heuristic decides it.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [extract_task_id!: 1, response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
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

  spex "A question about criteria goes to product, not to the user", criterion: 1608 do
    scenario "A coder asks about a criterion's wording and product answers it" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coder holding a story's task, and a product agent", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Refund policy",
            description: "A story whose criterion is unclear",
            acceptance_criteria: ["The stated behavior is specified"]
          )

        :ok =
          ProjectStateFixtures.apply_three_amigos_for_story(context.scope, story,
            persona_id: context.persona_id
          )

        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        product = Fixtures.running_agent(context.scope, role: "product", continuous: true)
        coder_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}

        {:reply, started, _} =
          StartTask.execute(
            %{
              requirement_name: "bdd_specs_exist",
              entity_type: "story",
              entity_id: to_string(story.number)
            },
            coder_frame
          )

        refute started.isError, response_text(started)

        {:ok,
         Map.merge(context, %{
           coder_frame: coder_frame,
           product_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: product.id}},
           task_id: extract_task_id!(started)
         })}
      end

      when_ "the coder asks about a criterion, saying it is about criteria", context do
        {:reply, asked, _} =
          AskUserQuestion.execute(
            %{
              task_id: context.task_id,
              about: "criteria",
              questions: [
                %{question: "Does criterion 944 still mean a full refund?", options: []}
              ]
            },
            context.coder_frame
          )

        refute asked.isError, response_text(asked)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(asked))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "it is waiting on product", context do
        {:reply, listing, _} = ListNotifications.execute(%{}, context.product_frame)

        assert response_text(listing) =~ context.question_id,
               "product was not handed the question about its own criteria:\n#{response_text(listing)}"

        {:ok, context}
      end

      then_ "and product's answer reaches the coder", context do
        {:reply, answered, _} =
          AnswerNotification.execute(
            %{id: context.question_id, answer: "Yes, full refund within 30 days."},
            context.product_frame
          )

        refute answered.isError, response_text(answered)

        {:reply, checked, _} =
          CheckAnswer.execute(%{question_id: context.question_id}, context.coder_frame)

        assert response_text(checked) =~ "full refund within 30 days"
        {:ok, context}
      end
    end
  end
end
