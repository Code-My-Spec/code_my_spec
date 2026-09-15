defmodule CodeMySpecWeb.DevGraphLiveNamesTheWakeTest do
  @moduledoc """
  The page has to show the end of the chain, not just the middle of it.

  "Rows are fresh" is where the watcher's job ends and where the claim does
  not. The observable feature is that an agent waiting on work is told when it
  appears, and a pass that recomputed perfectly and woke nobody looks exactly
  like one that recomputed perfectly and should have. Without this panel the
  page can only report the half that was never in doubt.

  So the assertion is that it names the requirement that appeared. A panel that
  says "nothing new" whatever the graph did is worse than no panel, because it
  is quoted.

  Separate from `DevGraphLiveTest` because it needs a fully-satisfied project:
  something can only *appear* against a previous pass, and on a bare fixture
  the actionable set never moves — see
  `filing_an_issue_reaches_the_role_that_triages_it_test.exs`.
  """

  use CodeMySpecSpex.Case, async: false

  # `/dev/graph` is a cloud-app route; the case's default endpoint is the local
  # app, where `live/2` answers 404 from inside LiveViewTest.
  @endpoint CodeMySpecWeb.Endpoint

  import Phoenix.LiveViewTest

  alias CodeMySpec.Issues
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The page mounts on the first project it lists, which is whichever sorts
  # first across the whole database — so a test that reads the mounted render
  # passes alone and reports another test's project when the suite runs
  # together. Driving the picker is what a person does anyway.
  defp open_on_this_project(ctx) do
    {:ok, view, _html} = live(ctx.conn, ~p"/dev/graph")

    html =
      view
      |> element("form[phx-change='select']")
      |> render_change(%{"project" => ctx.scope.active_project_id})

    {view, html}
  end

  test "the page names the requirement that appeared and when the wake went out", ctx do
    ctx = FullSatisfactionFixtures.apply(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {_view, html} = open_on_this_project(ctx)

    assert html =~ "What the last pass caused",
           "the panel that shows the end of the chain is not on the page"

    # The premise is that this name is not already on the page — not that the
    # panel reads "nothing new".
    #
    # `last_appeared` describes the last *pass*, and `settle/1` performs no pass
    # when nothing is pending, so the panel can still be reporting an
    # intermediate debounce pass that fired part-way through the fixture's
    # writes. That is the panel being accurate; asserting it says "nothing new"
    # asserts the fixture's writes all landed inside one debounce window, which
    # they do alone and do not under load.
    refute html =~ "issues_triaged",
           "the name is already on the page before the issue exists, so finding it later proves nothing"

    {:ok, _issue} =
      Issues.create_issue(ctx.scope, %{
        title: "something is wrong",
        description: "filed while product was idle",
        severity: :medium
      })

    :ok = GraphWatcher.settle(ctx.scope)

    {_view, html} = open_on_this_project(ctx)

    assert html =~ "issues_triaged",
           """
           An issue was filed, `issues_triaged` became actionable, and the panel
           that exists to say what a pass caused did not name it.

           This is the page's claim about the end of the chain. A panel that
           reads the same before and after the graph moved proves nothing, and
           is read as proof.

           #{html}
           """

    refute html =~ "Last wake sent</dt>\n              <dd class=\"tabular-nums\">never",
           "work appeared and the page still reports that no wake has ever been sent"
  end
end
