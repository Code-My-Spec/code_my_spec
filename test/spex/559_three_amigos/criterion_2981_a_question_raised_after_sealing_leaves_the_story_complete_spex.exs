defmodule CodeMySpecSpex.Story559.Criterion1060Spex do
  @moduledoc """
  Story 559 — Three Amigos.
  Criterion 1060 — A question added after sealing does not reopen the story.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "a question raised after sealing leaves Three Amigos complete", criterion: 1060 do
    scenario "the sealed story stays satisfied and does not re-enter discovery" do
      given_ :persona_exists

      given_ "the story has a covered rule and its Three Amigos task is sealed", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        assigns = Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        statement = "The project title appears on the summary page"

        assert {:ok, _} =
                 ToolLibrary.run(
                   "add_rule",
                   %{story_number: context.story.number, statement: statement},
                   assigns
                 )

        assert {:ok, _} =
                 ToolLibrary.run(
                   "add_scenario",
                   %{
                     story_number: context.story.number,
                     rule_statement: statement,
                     title: "Sam sees the project title",
                     kind: "happy_path",
                     body:
                       "Given Sam opens the summary\nWhen it loads\nThen the project title is shown"
                   },
                   assigns
                 )

        {:ok, context}
      end

      given_ :three_amigos_task_started

      given_ "evaluation has completed and sealed the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert {:ok, _} = response
        assert response_text(response) =~ ~r/passed|complete/i
        {:ok, context}
      end

      when_ "the agent adds a new question to the sealed story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "add_question",
            %{
              story_number: context.story.number,
              text: "Should the title be shortened on mobile?"
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :question_response, response)}
      end

      then_ "Three Amigos remains satisfied and discovery does not return the story", context do
        assert {:ok, _} = context.question_response
        frame = %Frame{assigns: %{current_scope: context.scope}}
        assigns = Map.put(frame.assigns, :scope, frame.assigns[:current_scope])

        requirements = ToolLibrary.run("list_requirements", %{}, assigns)
        assert {:ok, _} = requirements

        assert response_text(requirements) =~ ~r/\[x\]\s+\*\*three_amigos_complete\*\*/i,
               "expected the completed Three Amigos requirement to stay satisfied"

        next_response = ToolLibrary.run("get_next_requirement", %{}, assigns)
        assert {:ok, _} = next_response
        next_body = response_text(next_response)

        refute next_body =~ "three_amigos_complete" and
                 next_body =~ to_string(context.story.id),
               "expected the sealed story to stay out of the requirement queue"

        {:ok, context}
      end
    end
  end
end
