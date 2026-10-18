defmodule CodeMySpecSpex.Story559.Criterion5896Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5896 — `add_question` creates a Question (red card)
  attached to the story; the question is observable through
  `list_questions`.

  Covers Rule 6/7 from `examples.md`: questions are first-class
  persisted records on the story, mutated through MCP tools.

  Depends on:
    - `Questions` context (new)
    - `Question` schema (new)
    - `AddQuestion` MCP tool (new)
    - `ListQuestions` MCP tool (new)
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "add_question creates a Question record observable via list_questions", criterion: 163 do
    scenario "round-trip: add then list returns the question text" do
      given_ :persona_exists

      when_ "the agent calls add_question on the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "add_question",
            %{
              story_number: context.story.number,
              text: "Does suspension affect mid-transaction cards or only new transactions?"
            },
            Map.put(frame.assigns, :scope, frame.assigns.current_scope)
          )

        {:ok, Map.put(context, :add_response, response)}
      end

      then_ "the question is returned by list_questions for the story", context do
        assert match?({:ok, _}, context.add_response),
               "expected add_question to succeed, got #{inspect(context.add_response)}"

        frame = %Frame{assigns: %{current_scope: context.scope}}

        list_response =
          ToolLibrary.run("list_questions", %{story_number: context.story.number}, %{
            scope: frame.assigns.current_scope
          })

        body = response_text(list_response)

        assert body =~ "mid-transaction cards",
               "expected list_questions to return the question text, got #{inspect(list_response)}"

        {:ok, context}
      end
    end
  end
end
