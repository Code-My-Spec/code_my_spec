defmodule CodeMySpecSpex.Story995.Criterion8275Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8275 — A model that will not stop is stopped.

  Rule: The tool-calling loop is bounded.

  A model that keeps calling tools without concluding costs money on every
  round and never returns. Stopping it is the easy half; telling Sam is the
  half that matters, because a silent stop is indistinguishable from a hang.

  Surface: `CodeMySpecWeb.ChatLive` at `/app/projects/:project_id/chat`.
  """

  use CodeMySpecSpex.Case


  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Application.put_env(:code_my_spec, :chat_llm, %{
      tool_calls: [
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}},
        %{name: "list_stories", arguments: %{}}
      ],
      chunks_after_tool: []
    })

    on_exit(fn -> Application.delete_env(:code_my_spec, :chat_llm) end)
    :ok
  end

  spex "A runaway conversation is stopped and says so" do
    scenario "A model that will not stop is stopped" do
      given_ "the model keeps calling tools without concluding", context do
        {:ok, chat, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}/chat")

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "it reaches the step cap", context do
        html =
          context.chat
          |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
          |> render_submit()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the loop stops", context do
        assert has_element?(context.chat, "[data-test='chat-halted']"),
               "expected the runaway to be stopped at the cap"

        {:ok, context}
      end

      then_ "Sam is told the conversation ended early rather than left waiting", context do
        assert has_element?(context.chat, "[data-test='chat-halted']"),
               "expected Sam to be told, not left watching a spinner"

        refute has_element?(context.chat, "[data-test='chat-thinking']"),
               "a halted conversation must not still look like it is working"

        {:ok, context}
      end
    end
  end
end
