defmodule CodeMySpecSpex.Story995.Criterion8281Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8281 — The editor is the story UI not a second one.

  Rule: Sam can edit the story he was just shown without leaving the conversation.

  A bespoke form in the chat would be a second editing surface, and second
  surfaces drift — the one in the conversation would quietly stop matching the
  one on the stories page. Rendering the real component is what keeps them the
  same thing.

  Surface: `CodeMySpecWeb.ChatLive` at `/app/projects/:project_id/chat`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Application.put_env(:code_my_spec, :chat_llm, %{
      tool_calls: [
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

  spex "The conversation renders the real story editor" do
    scenario "The editor is the story UI, not a second one" do
      given_ "the conversation has created Sam's story and rendered it for him", context do
        {:ok, chat, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}/chat")

        chat
        |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
        |> render_submit()

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "he opens it to make a change", context do
        html = context.chat |> element("[data-test='story-card']") |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "he is editing through the same story UI the rest of the app uses", context do
        assert has_element?(context.chat, "[data-test='story-form']"),
               "expected the story form component itself, not a chat-local form"

        {:ok, context}
      end

      then_ "a change he makes there is the change the stories page shows", context do
        context.chat
        |> form("[data-test='story-form']", %{story: %{title: "Calendar of today's bookings"}})
        |> render_submit()

        {:ok, _stories_live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/stories")

        assert html =~ "Calendar of today's bookings",
               "expected the edit made in the conversation to be the story the page shows"

        {:ok, context}
      end
    end
  end
end
