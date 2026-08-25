defmodule CodeMySpecSpex.Story963.Criterion2918Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2918 — It answers about the project, not about a directory.

  Rule: The main agent has the run of the whole project — its records, its code, its tests and its problems.

  The PM's framing: "this guy should be the most privileged agent — he should
  be able to get in there and read files and check, run tests, see problems ...
  the main agent is like the CTO."

  So it is not one more per-checkout agent that happens to be labelled main. Its
  subject is the project.

  ## What a spex can assert here, and what it cannot

  This criterion is about what the agent *says*. A spex drives surfaces, not a
  model, so it cannot assert prose — and a check dressed up to look as though
  it does would go green while the thing the criterion cares about was wrong.

  So this asserts that one main agent serves a project with several checkouts, rather than one appearing per copy. Whether its answers actually range across the project is left to QA, where a person reads
  what the agent actually said.
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

  spex "The main agent has the run of the whole project — its records, its code, its tests and its problems" do
    scenario "It answers about the project, not about a directory" do
      given_ "a project with several working copies", context do
        first = CodeMySpec.TempFile.dir("spex_2918_first")
        second = CodeMySpec.TempFile.dir("spex_2918_second")
        third = CodeMySpec.TempFile.dir("spex_2918_third")
        Enum.each([first, second, third], &File.mkdir_p!/1)

        joined = join_working_copy(context, first, "the main checkout")
        join_working_copy(context, second, "another checkout")
        join_working_copy(context, third, "a third checkout")

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{joined.working_copy_id}"
          )

        live |> element("[data-test=designate-main-copy]") |> render_click()

        {:ok, context}
      end

      when_ "I ask the main agent what is happening on the project", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "its answer covers the project's stories, epics and requirements", context do
        assert context.html =~ "data-test=\"main-agent\"",
               "there is no main agent to ask"

        {:ok, context}
      end

      then_ "and it is not limited to the checkout it happens to run in", context do
        markers = Regex.scan(~r/data-test="main-agent"/, context.html)

        assert length(markers) == 1,
               "the project presents #{length(markers)} main agents across three " <>
                 "checkouts. One per copy is the per-checkout model this story exists " <>
                 "to replace."

        {:ok, context}
      end
    end
  end
end
