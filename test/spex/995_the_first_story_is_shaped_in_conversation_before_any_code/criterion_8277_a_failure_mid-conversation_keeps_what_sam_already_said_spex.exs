defmodule CodeMySpecSpex.Story995.Criterion8277Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8277 — A failure mid-conversation keeps what Sam already said.

  Rule: Answers already given survive a conversation that fails part-way.

  990 already decided this for the intake interview — a workspace that fails
  mid-interview does not throw the interview away. The same promise has to hold
  here, or a provider blip costs Sam the whole conversation.

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
      chunks_after_tool: [],
      error: :provider_unavailable
    })

    on_exit(fn -> Application.delete_env(:code_my_spec, :chat_llm) end)
    :ok
  end

  spex "A failed conversation does not cost Sam his answers" do
    scenario "A failure mid-conversation keeps what Sam already said" do
      given_ "Sam has answered some of the questions", context do
        {:ok, chat, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}/chat")

        chat
        |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
        |> render_submit()

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "the conversation fails before the story is created", context do
        html = render(context.chat)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "his answers are still there when he returns", context do
        {:ok, _returned, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/chat")

        assert html =~ "A booking tool for hair salons.",
               "expected Sam's answer to survive the failure, got: #{html}"

        {:ok, context}
      end

      then_ "the failure says it failed, rather than reading as a stop", context do
        {:ok, returned, _html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/chat")

        assert has_element?(returned, "[data-test='chat-failed']"),
               "expected a failure to be marked as one"

        refute has_element?(returned, "[data-test='chat-halted']"),
               "a provider failure is not a model that would not stop; they read differently"

        {:ok, context}
      end

      then_ "he is not asked them again", context do
        {:ok, returned, _html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/chat")

        assert has_element?(returned, "[data-test='message'][data-role='user']"),
               "expected his earlier answer to still be part of the conversation"

        {:ok, context}
      end
    end
  end
end
