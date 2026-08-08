defmodule CodeMySpecSpex.Story995.Criterion8273Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8273 — The review starts from a story already on the board.

  Rule: Three Amigos runs on the story only once the story exists.

  Three Amigos shapes a story that exists; it does not invent one. Running it
  against nothing is how sessions end up fabricating rules for a story nobody
  wrote.

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

  spex "The review follows the story rather than replacing it" do
    scenario "The review starts from a story already on the board" do
      given_ "the conversation has created Sam's story", context do
        {:ok, chat, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}/chat")

        chat
        |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
        |> render_submit()

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "Three Amigos is started for it", context do
        html = context.chat |> element("[data-test='start-three-amigos']") |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the session opens on that story", context do
        assert_redirected_to_three_amigos =
          context.html =~ "three-amigos" or
            has_element?(context.chat, "[data-test='three-amigos-started']")

        assert assert_redirected_to_three_amigos,
               "expected the review to open on the story just created"

        {:ok, context}
      end

      then_ "it carries the story Sam just approved", context do
        assert context.html =~ "Bookings show up on a calendar",
               "expected the review to be about Sam's story, got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
