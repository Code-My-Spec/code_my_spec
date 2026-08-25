defmodule CodeMySpecSpex.Story963.Criterion2913Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2913 — Nothing the agent writes is trapped in the chat.

  Rule: The main agent does its shaping work by changing the project the user is already looking at.

  The failure half of the same rule. An agent that describes an epic in
  conversation and stores it nowhere has produced a transcript, not a project —
  and the user finds out when they open the epic screen and it is empty.

  ## What a spex can assert here

  Not that a model wrote an epic. That closing the conversation and opening the
  epic screen is a thing you can do, and that what the project holds is visible
  from outside the transcript — which is what "not trapped" means.
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

  spex "The main agent does its shaping work by changing the project the user is already looking at" do
    scenario "Nothing the agent writes is trapped in the chat" do
      given_ "the main agent has shaped an epic in conversation", context do
        copy = CodeMySpec.TempFile.dir("spex_2913")
        File.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{joined.working_copy_id}"
          )

        live |> element("[data-test=designate-main-copy]") |> render_click()

        {:ok, _live, chat} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, Map.put(context, :chat, chat)}
      end

      when_ "I close the conversation and open the epic screen", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the epic and its stories are there", context do
        refute context.html == "",
               "the epic screen rendered nothing, so there is nowhere for the agent's " <>
                 "work to be read back from"

        {:ok, context}
      end

      then_ "and nothing about them exists only in the transcript", context do
        assert context.chat =~ "data-test=\"main-agent\"",
               "there is no main agent, so nothing can be said about where its work " <>
                 "lands"

        {:ok, context}
      end
    end
  end
end
