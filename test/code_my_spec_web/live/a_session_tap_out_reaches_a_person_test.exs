defmodule CodeMySpecWeb.ASessionTapOutReachesAPersonTest do
  @moduledoc """
  A Claude Code session's `tap_out` is a request a person can see and answer.

  e96115a9: the session path wrote only `session.state["pending_tap_out"]`,
  which nothing in the UI reads, and still replied "published — awaiting
  human approval". The person could not find it, and the stop hook refused
  eleven stops.
  """
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.SessionsFixtures

  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpec.Repo
  alias CodeMySpec.Sessions.Session
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup %{scope: scope} do
    external_id = "claude-#{System.unique_integer([:positive])}"
    session = session_fixture(scope, %{external_conversation_id: external_id, continuous: true})
    %{session: session, external_id: external_id}
  end

  defp tap_out(scope, external_id) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: scope}}
    {:reply, response, _} = TapOut.execute(%{session_id: external_id, reason: "done"}, frame)
    refute response.isError, TaskResponseHelpers.response_text(response)
    [_, id] = Regex.run(~r/request_id=`([^`]+)`/, TaskResponseHelpers.response_text(response))
    id
  end

  defp continuous?(session), do: Repo.get!(Session, session.id).continuous

  test "the request is listed in the person's notifications inbox", ctx do
    id = tap_out(ctx.scope, ctx.external_id)

    {:ok, view, _html} = live(ctx.conn, ~p"/app/notifications")

    assert view |> element("section", "Pending") |> render() =~ ~p"/app/permissions/#{id}"
  end

  test "approving it clears the session's continuous mode", ctx do
    id = tap_out(ctx.scope, ctx.external_id)

    {:ok, view, _html} = live(ctx.conn, ~p"/app/permissions/#{id}")
    view |> element("[data-test='approve-permission']") |> render_click()

    assert has_element?(view, "[data-test='permission-resolved']", "approved")
    refute continuous?(ctx.session)
  end

  test "rejecting it leaves continuous mode on", ctx do
    id = tap_out(ctx.scope, ctx.external_id)

    {:ok, view, _html} = live(ctx.conn, ~p"/app/permissions/#{id}")

    view
    |> element("#permission-#{id}-confirm-deny [data-role='confirm-confirm']")
    |> render_click()

    assert has_element?(view, "[data-test='permission-resolved']", "denied")
    assert continuous?(ctx.session)
  end

  test "asking again while one is pending reuses it", ctx do
    first = tap_out(ctx.scope, ctx.external_id)
    assert tap_out(ctx.scope, ctx.external_id) == first
  end
end
