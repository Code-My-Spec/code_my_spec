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
        {:ok, chat, _html} = live(context.conn, "/app/projects/#{context.project.id}/chat")

        chat
        |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
        |> render_submit()

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "Three Amigos is started for it", context do
        # The click navigates, so `render_click` raises rather than returning
        # HTML. Catching the redirect is how the destination is observed.
        {:error, {:live_redirect, %{to: to}}} =
          context.chat |> element("[data-test='start-three-amigos']") |> render_click()

        {:ok, follow, html} = live(context.conn, to)

        {:ok, context |> Map.put(:to, to) |> Map.put(:review, follow) |> Map.put(:html, html)}
      end

      then_ "the session opens on that story", context do
        # Asserted against where the click went, not against a substring of the
        # page it was clicked on. The previous version was
        #
        #     context.html =~ "three-amigos"
        #
        # and the button's own `data-test="start-three-amigos"` contains that
        # string — so it held before the click and after it, whatever the
        # handler did. It held while the handler set an assign nothing rendered
        # and the button was a dead click (issue `1366f527`), which is how a
        # green criterion and a broken button coexisted for as long as they did.
        #
        # A dead button produces no redirect at all, so the `when_` step's match
        # already fails on the defect. This pins the destination; the step below
        # pins *which* story, by reading the review page rather than the page the
        # button was on — which is the other half of what was wrong. `context.html`
        # used to be the chat page, where the story title is trivially present.
        assert context.to =~ ~r"^/app/projects/#{context.project.id}/stories/\d+/three-amigos$",
               "expected the review to open on a story in this project, got: #{context.to}"

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
