defmodule CodeMySpecSpex.Story686.Criterion7949Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 7949 — Downstream tasks read the story sentence, not the notes.

  The split only pays off if consumers can tell the two apart. Spec writers
  and BDD writers must receive the story sentence as the story — never the
  agent's scratch notes concatenated into it.

  Surface: `get_story` MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.GetStory

  setup :register_log_in_setup_account
  setup :setup_active_project

  @story "As a driver, I want a guided sign-up so that I can start earning."
  @notes "SCRATCHPAD-MARKER: blocked on the identity provider migration."

  spex "Downstream tasks read the story sentence, not the notes" do
    scenario "The sentence and the notes come back as separate values" do
      given_ "a story carrying both a user-story sentence and working notes", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateStory.execute(
            %{title: "Driver onboarding", story: @story, notes: @notes},
            frame
          )

        refute response.isError, "expected create_story to succeed, got: #{inspect(response)}"

        {:ok, context |> Map.put(:frame, frame) |> Map.put(:story_id, story_id!(response))}
      end

      when_ "a downstream task reads that story", context do
        {:reply, response, _frame} =
          GetStory.execute(%{story_id: context.story_id}, context.frame)

        refute response.isError, "expected get_story to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :story_body, response_text(response))}
      end

      then_ "it receives the story sentence and the notes as separate values", context do
        body = context.story_body

        assert body =~ @story,
               "expected the story sentence to be present, got: #{body}"

        assert body =~ "Notes",
               "expected the notes to be surfaced under their own labelled field, got: #{body}"

        refute body =~ "#{@story} #{@notes}",
               "expected the notes NOT to be concatenated into the story sentence, got: #{body}"

        {:ok, context}
      end
    end
  end

  # MCP responses carry record ids in the text footer.
  defp story_id!(response) do
    body = response_text(response)

    case Regex.run(~r/\(ID: (\d+)\)/, body) do
      [_, id] -> id
      _ -> raise "could not read story id from response: #{body}"
    end
  end
end
