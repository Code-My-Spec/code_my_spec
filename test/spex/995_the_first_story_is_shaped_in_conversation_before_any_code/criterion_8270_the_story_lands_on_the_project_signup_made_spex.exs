defmodule CodeMySpecSpex.Story995.Criterion8270Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8270 — The story lands on the project signup made.

  Rule: The story belongs to the project the intake form created at signup.

  Signup already created the account and project from the confirmed plan.
  A story that landed anywhere else would be invisible on the project Sam is
  about to work in, which is the same as not having been created.

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

  spex "The story is created on the project signup already made" do
    scenario "The story lands on the project signup made" do
      given_ "Sam signed up through the intake form", context do
        {:ok, chat, _html} = live(context.conn, "/app/projects/#{context.project.id}/chat")

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "the conversation creates his story", context do
        context.chat
        |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
        |> render_submit()

        {:ok, context}
      end

      then_ "the story belongs to the project that signup created", context do
        {:ok, _stories_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/stories")

        assert html =~ "Bookings show up on a calendar",
               "expected the story to appear on the signup project's stories page"

        {:ok, context}
      end
    end
  end
end
