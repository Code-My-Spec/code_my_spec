defmodule CodeMySpecSpex.Story995.Criterion8268Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8268 — Four answers become one story.

  Rule: The conversation produces exactly one story.

  The whole promise of the guided path is that Sam ends up with something
  concrete without writing it himself. One story is the payout — not a backlog
  he now has to triage, and not nothing.

  Surface: `CodeMySpecWeb.ChatLive` at `/app/projects/:project_id/chat` — the
  two-way agent chat someone lands in after signup. Distinct from the intake
  interview on `/build/workspace`, which runs earlier and stops at derived
  rules.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The provider is scripted rather than called. `:chat_llm` describes what the
  # model does — the tool calls it makes and the text it emits after each —
  # while the runner, the tool dispatch, persistence and the LiveView all run
  # for real. Mirrors the seam MarketMySpec's chat runner already uses.
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

  spex "The conversation turns answers into a story" do
    scenario "Four answers become one story" do
      given_ "Sam has just signed up and his project exists", context do
        {:ok, chat, _html} = live(context.conn, "/app/projects/#{context.project.id}/chat")

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "he answers the interview questions", context do
        html =
          context.chat
          |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "one story is created on that project", context do
        assert has_element?(context.chat, "[data-test='story-card']"),
               "expected the created story to be shown in the conversation"

        assert context.html =~ "Bookings show up on a calendar",
               "expected the story the model created to be visible, got: #{context.html}"

        {:ok, context}
      end

      then_ "it is the only story the conversation created", context do
        assert context.chat |> element("[data-test='story-card']") |> has_element?()

        refute has_element?(context.chat, "[data-test='story-card']:nth-of-type(2)"),
               "expected exactly one story, not a backlog"

        {:ok, context}
      end
    end
  end
end
