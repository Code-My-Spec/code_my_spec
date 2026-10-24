defmodule CodeMySpecWeb.WorkingCopyLive.AppStatusBadgeTest do
  @moduledoc """
  Story 1108 gave every working copy its own `app_status`/`app_commit`, and
  before this test there was no surface showing either — the exact gap QA
  found while verifying story 1046 (QA runs against a copy's own app before
  promotion): nothing on `/app/projects/:id/working-copies` said whether a
  copy's own app was up or what commit it was serving, so a stuck copy read
  no differently from a healthy one anywhere but the database.
  """

  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpecSpex.WorkingCopyHelpers
  import Phoenix.LiveViewTest

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.AppInstances
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp index(context) do
    {:ok, live, _html} =
      live(context.conn, "/app/projects/#{context.scope.active_project_id}/working-copies")

    live
  end

  test "a copy whose app is serving shows its status and commit", context do
    copy = join_working_copy(context, "/tmp/app-status-serving", "a copy with a serving app")
    {:ok, harness} = WorkingCopies.fetch(copy.working_copy_id)
    instance = AppInstances.for_working_copy(context.scope, harness)

    {:ok, _instance} =
      AppInstances.record_status(context.scope, instance, %{
        status: "serving",
        url: "http://127.0.0.1:4100",
        commit: "cafef00dcafef00dcafef00dcafef00dcafef00d"
      })

    live = index(context)

    assert has_element?(live, "[data-app-status='serving']"),
           "a copy with a serving app should show that status on the working " <>
             "copies list — this is the only place that fact is visible outside the DB."

    html = live |> element("[data-app-status='serving']") |> render()

    assert html =~ "cafef00d",
           "the badge should name the commit the app is serving, truncated for the " <>
             "row rather than the full sha. Got: #{html}"
  end

  test "a copy whose app is down shows that status, distinctly from serving", context do
    copy = join_working_copy(context, "/tmp/app-status-down", "a copy with a down app")
    {:ok, harness} = WorkingCopies.fetch(copy.working_copy_id)
    instance = AppInstances.for_working_copy(context.scope, harness)

    {:ok, _instance} = AppInstances.record_status(context.scope, instance, %{status: "down"})

    live = index(context)

    assert has_element?(live, "[data-app-status='down']"),
           "a copy whose app is down should read differently from one that is serving."

    refute has_element?(live, "[data-app-status='serving']"),
           "the down copy's row should not also claim to be serving."
  end

  test "a copy nothing has ever checked shows no app-status badge at all", context do
    _copy = join_working_copy(context, "/tmp/app-status-unchecked", "a copy never checked")

    live = index(context)

    refute has_element?(live, "[data-test='working-copy-app-status']"),
           "a copy with no app_status yet (never checked, or a harness too old to " <>
             "report) should not show a badge claiming a status it has not reported — " <>
             "nil is a real 'nothing to say' state, not evidence of being down."
  end
end
