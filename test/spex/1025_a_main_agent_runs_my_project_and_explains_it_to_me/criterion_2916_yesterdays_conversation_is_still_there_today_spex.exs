defmodule CodeMySpecSpex.Story963.Criterion2916Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2916 — Yesterday's conversation is still there today.

  Rule: The main agent picks up the same conversation every time, however long it has been.

  A project runs for months and the conversation about it is the record of why
  it looks the way it does. An agent that starts fresh each session makes the
  user the memory, which is exactly the job this agent was meant to take off
  them.

  Story 962 made the conversation durable — it is rows, and the page reads them
  back. What is missing is the other half: an agent that comes back *to* it,
  rather than a transcript nobody is holding.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent picks up the same conversation every time, however long it has been" do
    scenario "Yesterday's conversation is still there today" do
      given_ "I talked to the main agent yesterday about my project", context do
        copy = CodeMySpec.TempFile.dir("spex_2916")
        File.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{joined.working_copy_id}"
          )

        live |> element("[data-test=designate-main-copy]") |> render_click()

        {:ok, chat, _html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        chat
        |> form("form[phx-submit=send_message]", %{"message" => "remember the pricing rule"})
        |> render_submit()

        {:ok, Map.put(context, :copy, copy)}
      end

      when_ "I open the project today", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the same conversation is there with everything we said", context do
        assert context.html =~ "remember the pricing rule",
               "what I said to the main agent is gone. A project's conversation is the " <>
                 "record of why it looks the way it does, and an agent that starts " <>
                 "fresh makes the user the memory."

        {:ok, context}
      end

      then_ "and I can carry on without repeating myself", context do
        assert context.html =~ "phx-submit=\"send_message\"",
               "there is nowhere to carry on from"

        {:ok, context}
      end
    end
  end
end
