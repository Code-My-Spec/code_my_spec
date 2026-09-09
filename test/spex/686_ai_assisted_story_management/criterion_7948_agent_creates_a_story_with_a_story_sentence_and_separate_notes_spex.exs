defmodule CodeMySpecSpex.Story686.Criterion7948Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 7948 — Agent creates a story with a story sentence and separate notes.

  The user-story sentence and the agent's own working notes are distinct
  fields. The sentence stays a clean "As an X, I want Y, so that Z"; notes
  are where mechanism, dependencies and caveats go.

  Surface: `create_story` and `get_story` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateStory
  alias CodeMySpec.McpServers.Stories.Tools.GetStory

  setup :register_log_in_setup_account
  setup :setup_active_project

  @story "As a driver, I want a guided sign-up so that I can start earning."
  @notes "Depends on the identity provider migration; revisit once OAuth lands."

  spex "Agent creates a story with a story sentence and separate notes" do
    scenario "Both are stored on the story as distinct fields" do
      given_ "the agent is creating a story", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      when_ "it supplies the user-story sentence and separate working notes", context do
        {:reply, response, _frame} =
          CreateStory.execute(
            %{title: "Driver onboarding", story: @story, notes: @notes},
            context.frame
          )

        refute response.isError,
               "expected create_story to accept separate story and notes fields, got: #{inspect(response)}"

        {:ok, Map.put(context, :story_id, story_id!(response))}
      end

      then_ "both are stored on the story as distinct fields", context do
        {:reply, response, _frame} =
          GetStory.execute(%{story_id: context.story_id}, context.frame)

        body = response_text(response)

        refute response.isError, "expected get_story to succeed, got: #{inspect(response)}"

        assert body =~ @story,
               "expected the user-story sentence to be stored, got: #{body}"

        assert body =~ @notes,
               "expected the working notes to be stored, got: #{body}"

        {:ok, context}
      end
    end
  end

  # MCP responses carry record ids in the text footer.
  defp story_id!(response) do
    response |> response_text() |> story_id_from()
  end

  defp story_id_from(body), do: story_id_match(Regex.run(~r/\(ID: (\d+)\)/, body), body)

  defp story_id_match([_, id], _body), do: id

  defp story_id_match(_no_match, body),
    do: raise("could not read story id from response: #{body}")
end
