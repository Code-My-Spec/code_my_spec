defmodule CodeMySpecSpex.Story995.Criterion8269Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8269 — A second story is refused not silently added.

  Rule: The conversation produces exactly one story.

  A model that keeps going is the likely failure, not a rare one. If a second
  create slips through, Sam's payout stops being one clear thing and becomes a
  list he has to sort out — which is what the guided path exists to spare him.

  Surface: `CodeMySpecWeb.ChatLive` at `/app/projects/:project_id/chat` — the
  two-way agent chat someone lands in after signup. Distinct from the intake
  interview on `/build/workspace`, which runs earlier and stops at derived
  rules.
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
        },
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

  spex "The conversation refuses to create more than one story" do
    scenario "A second story is refused, not silently added" do
      given_ "the conversation has already created Sam's story", context do
        {:ok, chat, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}/chat")

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "the model attempts to create another", context do
        html =
          context.chat
          |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the second is refused", context do
        assert context.html =~ "Bookings show up on a calendar",
               "anchor: the first story should still be here"

        refute has_element?(context.chat, "[data-test='story-card']:nth-of-type(2)"),
               "expected the second create to be refused"

        {:ok, context}
      end

      then_ "Sam still has exactly one story", context do
        {:ok, _stories_live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/stories")

        titles = html |> String.split("Bookings show up on a calendar") |> length()

        assert titles == 2,
               "expected the story to appear exactly once on the stories page"

        {:ok, context}
      end
    end
  end
end
