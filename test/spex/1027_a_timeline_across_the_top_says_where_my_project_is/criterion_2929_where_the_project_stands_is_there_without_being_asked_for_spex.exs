defmodule CodeMySpecSpex.Story965.Criterion2929Spex do
  @moduledoc """
  Story 965 — A timeline across the top says where my project is.
  Criterion 2929 — Where the project stands is there without being asked for.

  Rule: The timeline sits across the top of the project's pages rather than on a
  page of its own.

  Why this is a component and not a screen. A page you have to navigate to is a
  page a non-technical user has to know exists, and knowing which of eleven
  project pages answers "how is it going" is the problem the timeline removes.
  On a page of its own it would be the twelfth.

  So it rides the layout, and the test of that is that it is on pages which have
  nothing to do with it.
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

  spex "The timeline sits across the top of the project's pages rather than on a page of its own" do
    scenario "Where the project stands is there without being asked for" do
      given_ "I own a project", context do
        # Established rather than assumed. "Part-way" means some of the
        # project's own requirements are met and some are not; on a project
        # where everything is satisfied the timeline is a different picture and
        # a block that only says so would not notice.
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/requirements")

        assert html =~ "requirement",
               "the requirements page shows nothing, so there is no project state for " <>
                 "the timeline to be part-way through"

        {:ok, context}
      end

      when_ "I open pages of it that have nothing to do with progress", context do
        # Three unrelated ones. A timeline present on the stories page proves
        # only that somebody put it there; present on stories, issues and
        # working copies alike, it is in the layout.
        pages =
          for path <- ~w(stories issues working-copies) do
            {:ok, _live, html} =
              live(context.conn, "/app/projects/#{context.project.id}/#{path}")

            {path, html}
          end

        {:ok, Map.put(context, :pages, pages)}
      end

      then_ "the timeline is across the top of each of them", context do
        for {path, html} <- context.pages do
          assert html =~ "data-test=\"project-timeline\"",
                 "the #{path} page has no timeline. On a page of its own it would be the " <>
                   "twelfth project page somebody has to know exists, which is the " <>
                   "problem it was built to remove."
        end

        {:ok, context}
      end

      then_ "and it is across the top, above what the page is for", context do
        for {path, html} <- context.pages do
          timeline = :binary.match(html, "data-test=\"project-timeline\"") |> elem(0)
          content = :binary.match(html, "<main") |> elem(0)

          assert timeline < content,
                 "on the #{path} page the timeline renders after the page's own content. " <>
                   "Across the top is the whole placement — below the fold it is a footer " <>
                   "nobody scrolls to."
        end

        {:ok, context}
      end
    end
  end
end
