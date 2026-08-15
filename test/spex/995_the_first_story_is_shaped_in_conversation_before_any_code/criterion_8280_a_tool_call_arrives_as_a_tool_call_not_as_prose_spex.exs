defmodule CodeMySpecSpex.Story995.Criterion8280Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8280 — A tool call arrives as a tool call not as prose.

  Rule: A tool call keeps its structure from the model through to the screen.

  The old message model flattened everything into a text body, which is why
  the agent view had to special-case blank turns and hide them. A call that
  arrives as prose cannot be rendered as a call, and cannot be replayed.

  Surface: `CodeMySpecWeb.ChatLive` at `/app/projects/:project_id/chat` — the
  two-way agent chat someone lands in after signup. Distinct from the intake
  interview on `/build/workspace`, which runs earlier and stops at derived
  rules.
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

  spex "A tool call survives the trip with its shape intact" do
    scenario "A tool call arrives as a tool call, not as prose" do
      given_ "the model calls a story tool during the conversation", context do
        {:ok, chat, _html} = live(context.conn, "/app/projects/#{context.project.id}/chat")

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "that turn is recorded and shown to Sam", context do
        html =
          context.chat
          |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the call and its result keep their structure", context do
        assert has_element?(context.chat, "[data-test='tool-call'][data-tool='create_story']"),
               "expected the call to name the tool it called, not describe it in a sentence"

        assert has_element?(context.chat, "[data-test='tool-result'][data-tool-call-id]"),
               "expected the result to be paired to its call by id"

        {:ok, context}
      end

      then_ "nothing about the call has been flattened into a line of text", context do
        refute has_element?(context.chat, "[data-test='message'][data-role='tool']"),
               "a tool call should not arrive as a plain message with a text body"

        {:ok, context}
      end
    end
  end
end
