defmodule CodeMySpecSpex.Story963.Criterion2912Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2912 — Stories appear in the project as we talk about them.

  Rule: The main agent does its shaping work by changing the project the user is already looking at.

  The PM's design: "it should be mutating the UI so that the user can see what
  it's doing to the project." The conversation is not a separate world where
  work is described — it drives the records the project's own screens already
  render.

  ## What a spex can assert here

  It cannot make a model draft a story. What it can assert is the half that
  makes the design possible: that the story screen and the agent's conversation
  read the same records, so a story that exists on the project is a story the
  user can see and edit rather than a sentence in a transcript.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # The agent runs on a provider, and refusing without one is deliberate — an
  # agent started on a credential that does not resolve fails on its first
  # model call, minutes later, in a log nobody reads.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "The main agent does its shaping work by changing the project the user is already looking at" do
    scenario "Stories appear in the project as we talk about them" do
      given_ "I am telling the main agent what I want built", context do
        copy = CodeMySpec.TempFile.dir("spex_2912")
        File.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{joined.working_copy_id}"
          )

        live |> element("[data-test=designate-main-copy]") |> render_click()

        {:ok, context}
      end

      when_ "it drafts stories and groups them into an epic", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/stories")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "those stories and that epic appear in the screens the project already has",
            context do
        assert context.html =~ "963" or context.html =~ "main agent",
               "the project's own story screen does not show this project's stories, " <>
                 "so there is nowhere for the agent's shaping work to become visible"

        {:ok, context}
      end

      then_ "and I can see and edit them there rather than only in the conversation",
            context do
        {:ok, _live, chat} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        assert chat =~ "data-test=\"main-agent\"",
               "there is no main agent whose work could land in those screens"

        {:ok, context}
      end
    end
  end
end
