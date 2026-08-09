defmodule CodeMySpecSpex.Story995.Criterion8278Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8278 — Sam steps away and picks up where he left off.

  Rule: Answers already given survive a conversation that fails part-way.

  Nothing has gone wrong here — he just closed the tab. The conversation is
  durable state, not a page's memory, which is the same property 990 gave the
  plan.

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

  spex "The conversation is durable, not a page's memory" do
    scenario "Sam steps away and picks up where he left off" do
      given_ "Sam has answered some of the questions", context do
        {:ok, chat, _html} = live(context.conn, "/app/projects/#{context.project.id}/chat")

        chat
        |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
        |> render_submit()

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "he closes the tab and comes back", context do
        {:ok, returned, html} =
          live(context.conn, "/app/projects/#{context.project.id}/chat")

        {:ok, Map.merge(context, %{returned: returned, html: html})}
      end

      then_ "the conversation is where he left it", context do
        assert context.html =~ "A booking tool for hair salons.",
               "expected the conversation to still hold what he said"

        {:ok, context}
      end

      then_ "his earlier answers are still part of it", context do
        assert has_element?(context.returned, "[data-test='message'][data-role='user']"),
               "expected his earlier turn to still be in the thread"

        {:ok, context}
      end
    end
  end
end
