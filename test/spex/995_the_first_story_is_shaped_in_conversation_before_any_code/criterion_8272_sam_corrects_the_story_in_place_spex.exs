defmodule CodeMySpecSpex.Story995.Criterion8272Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8272 — Sam corrects the story in place.

  Rule: Sam can edit the story he was just shown without leaving the conversation.

  The model will get the wording slightly wrong, and Sam is the only one who
  knows how. Sending him elsewhere to fix a word is how a two-minute payout
  turns back into a chore.

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

  spex "Sam can correct what the model wrote" do
    scenario "Sam corrects the story in place" do
      given_ "the conversation has created Sam's story and shown it to him", context do
        {:ok, chat, _html} = live(context.conn, "/app/projects/#{context.project.id}/chat")

        chat
        |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
        |> render_submit()

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "he changes its wording", context do
        context.chat |> element("[data-test='story-card']") |> render_click()

        context.chat
        |> form("[data-test='story-form']", %{
          story: %{title: "Bookings for today show up on a calendar"}
        })
        |> render_submit()

        {:ok, context}
      end

      then_ "the change is saved to that story", context do
        {:ok, _stories_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/stories")

        assert html =~ "Bookings for today show up on a calendar",
               "expected Sam's correction to be the story that was saved, got: #{html}"

        {:ok, context}
      end

      then_ "he is still in the conversation", context do
        assert has_element?(context.chat, "[data-test='chat-compose']"),
               "expected Sam to still be able to talk to the agent after editing"

        {:ok, context}
      end
    end
  end
end
