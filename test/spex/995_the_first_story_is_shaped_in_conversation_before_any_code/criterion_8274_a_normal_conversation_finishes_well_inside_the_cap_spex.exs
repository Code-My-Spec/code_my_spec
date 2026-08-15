defmodule CodeMySpecSpex.Story995.Criterion8274Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8274 — A normal conversation finishes well inside the cap.

  Rule: The tool-calling loop is bounded.

  The cap exists to stop a runaway, not to ration ordinary work. If a normal
  interview runs anywhere near it, the cap is set wrong and will start
  truncating real conversations.

  Surface: `CodeMySpecWeb.ChatLive` at `/app/projects/:project_id/chat`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Application.put_env(:code_my_spec, :chat_llm, %{
      tool_calls: [
        %{name: "list_stories", arguments: %{}},
        %{
          name: "create_story",
          arguments: %{
            "title" => "Bookings show up on a calendar",
            "story" =>
              "As a salon owner, I want to see today's bookings on a calendar, so that I know who is coming in."
          }
        }
      ],
      chunks_after_tool: ["Here is the story I captured."]
    })

    on_exit(fn -> Application.delete_env(:code_my_spec, :chat_llm) end)
    :ok
  end

  spex "An ordinary conversation is nowhere near the limit" do
    scenario "A normal conversation finishes well inside the cap" do
      given_ "the conversation is running", context do
        {:ok, chat, _html} = live(context.conn, "/app/projects/#{context.project.id}/chat")

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "the model works through its questions and creates the story", context do
        html =
          context.chat
          |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it finishes within the step cap", context do
        assert has_element?(context.chat, "[data-test='story-card']"),
               "anchor: the conversation should have got as far as a story"

        refute has_element?(context.chat, "[data-test='chat-halted']"),
               "an ordinary conversation must not hit the cap"

        {:ok, context}
      end
    end
  end
end
