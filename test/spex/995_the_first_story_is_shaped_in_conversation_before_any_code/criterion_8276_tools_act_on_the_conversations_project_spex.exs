defmodule CodeMySpecSpex.Story995.Criterion8276Spex do
  @moduledoc """
  Story 995 — The first story is shaped in conversation, before any code.
  Criterion 8276 — Tools act on the conversations project.

  Rule: The conversation fixes the project; it is never resolved from a working directory.

  Every MCP tool falls back to resolving scope from a working directory when
  the frame carries none. Server-side there is no working directory to resolve,
  and a fallback that silently picks the wrong project is worse than an error.
  The conversation is the identity.

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

  spex "The conversation's project is the one the tools act on" do
    scenario "Tools act on the conversation's project" do
      given_ "a conversation belonging to Sam's project", context do
        other = CodeMySpecSpex.Fixtures.project_fixture(context.scope)

        {:ok, chat, _html} = live(context.conn, "/app/projects/#{context.project.id}/chat")

        {:ok, Map.merge(context, %{chat: chat, other_project: other})}
      end

      when_ "the model calls a story tool", context do
        context.chat
        |> form("[data-test='chat-compose']", %{message: "A booking tool for hair salons."})
        |> render_submit()

        {:ok, context}
      end

      then_ "the tool acts on that project", context do
        {:ok, _stories_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/stories")

        assert html =~ "Bookings show up on a calendar",
               "expected the story on the conversation's own project"

        {:ok, context}
      end

      then_ "no working directory is consulted to decide which", context do
        {:ok, _other_live, other_html} =
          live(context.conn, "/app/projects/#{context.other_project.id}/stories")

        refute other_html =~ "Bookings show up on a calendar",
               "the story must not land on a project the conversation does not belong to"

        {:ok, context}
      end
    end
  end
end
