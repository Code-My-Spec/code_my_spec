defmodule CodeMySpecSpex.Story559.Criterion5171Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5171 — `add_question` creates a Question (red card)
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

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.BddRules.Tools.AddQuestion
  alias CodeMySpec.McpServers.BddRules.Tools.ListQuestions

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "add_question creates a Question record observable via list_questions" do
    scenario "round-trip: add then list returns the question text" do
      given_ :persona_exists

      when_ "the agent calls add_question on the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AddQuestion.execute(
            %{
              story_id: context.story.id,
              text: "Does suspension affect mid-transaction cards or only new transactions?"
            },
            frame
          )

        {:ok, Map.put(context, :add_response, response)}
      end

      then_ "the question is returned by list_questions for the story", context do
        refute context.add_response.isError == true,
               "expected add_question to succeed, got #{inspect(context.add_response)}"

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, list_response, _frame} =
          ListQuestions.execute(%{story_id: context.story.id}, frame)

        body = response_text(list_response)

        assert body =~ "mid-transaction cards",
               "expected list_questions to return the question text, got #{inspect(list_response)}"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
