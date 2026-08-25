defmodule CodeMySpecSpex.Story963.Criterion2906Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2906 — A project with no main working copy says so instead of failing quietly.

  Rule: The main agent runs in the project's main working copy.

  The main agent needs a checkout to run in, and a brand new project has none.
  That is an ordinary state rather than a fault, and the two ways of getting it
  wrong are both worse than saying so: an error the user cannot act on, or a
  page that looks fine and answers nothing.

  `Engine.start/1` already refuses a checkout that is not there — with
  `:working_copy_missing`, which is the right refusal at the wrong altitude for
  somebody who does not know what a working copy is.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent runs in the project's main working copy" do
    scenario "A project with no main working copy says so instead of failing quietly" do
      given_ "a project that has no main working copy yet", context do
        # Established rather than assumed. A project's first checkout becomes
        # its main one, so the premise is that it has none — and a block that
        # only says so would pass on a project with six, testing something
        # else entirely without anybody noticing.
        {:ok, _copies, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

        refute html =~ "data-test=\"main-copy\"",
               "the premise is a project with no main working copy, and this one has " <>
                 "one — so what follows would be about a different project than the " <>
                 "criterion describes"

        {:ok, context}
      end

      when_ "I open it and try to talk to the main agent", context do
        {:ok, live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "I am told what is missing and how to supply it", context do
        assert context.html =~ ~r/working copy|checkout/i,
               "the page says nothing about the thing that is missing. An empty screen " <>
                 "and a working project look identical here, and the user has no way " <>
                 "to find out which they are looking at."

        {:ok, context}
      end

      then_ "and nothing reports an agent as running", context do
        refute context.html =~ "data-test=\"main-agent\"",
               "a main agent is presented for a project that has nowhere to run one. " <>
                 "Whatever is typed at it cannot reach anybody."

        {:ok, context}
      end
    end
  end
end
