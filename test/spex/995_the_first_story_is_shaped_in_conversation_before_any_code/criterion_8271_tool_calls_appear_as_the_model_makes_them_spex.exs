defmodule CodeMySpecSpex.Story995.Criterion8271Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8271 — Tool calls appear as the model makes them.

  Rule: Sam watches the tool calls as they happen.

  A conversation that goes quiet while something happens off-screen reads as
  broken. Showing the call as it is made is what turns a wait into progress —
  the same trick 990 used to make boot time bearable.

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

  spex "The work is visible while it happens" do
    scenario "Tool calls appear as the model makes them" do
      given_ "the conversation is running", context do
        {:ok, chat, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}/chat")

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "the model calls a tool", context do
        html =
          context.chat
          |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "Sam sees that call and what it returned", context do
        assert has_element?(context.chat, "[data-test='tool-call'][data-tool='create_story']"),
               "expected the create_story call to be shown to Sam"

        assert has_element?(context.chat, "[data-test='tool-result']"),
               "expected what the call returned to be shown too"

        {:ok, context}
      end

      then_ "he sees it while it happens, not only afterwards", context do
        assert has_element?(context.chat, "[data-test='tool-call'][data-state='running']") or
                 has_element?(context.chat, "[data-test='tool-call'][data-state='done']"),
               "expected the call to carry a state so it can render before it finishes"

        {:ok, context}
      end
    end
  end
end
