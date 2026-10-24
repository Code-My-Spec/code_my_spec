defmodule CodeMySpecWeb.AgentConversationLive.PreviewStateTest do
  @moduledoc """
  `PreviewComponents.pane/1` has five states for exactly this reason — its own
  moduledoc: "`:down` says a thing that existed has stopped. Conflating it
  with `:starting` is how a broken app reads as a slow one." Before this,
  `AgentConversationLive` computed only two: `:absent` when there was no
  `preview_url` at all, `:running` for anything else.

  That collapsed the gap between "a URL exists" and "the app behind it is
  actually answering" into nothing. `PreviewTunnel.ensure/1` mints the url at
  instance-boot time, before the container has even started; `cloudflared`
  comes up inside the app it is tunneling for, seconds to tens of seconds
  later. For that whole window the pane framed a tunnel nothing was serving —
  Cloudflare's own error page rendered inside "Your app", read by the person
  watching as their app being broken, when it was only still coming up.
  Measured live 2026-09-22 against a real project's first boot.
  """
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.AppInstances

  setup [:register_log_in_setup_account]

  defp setup_project(%{scope: scope, account: account} = context) do
    project =
      CodeMySpec.ProjectsFixtures.project_fixture(scope,
        account_id: account.id,
        name: "preview-state-project"
      )

    Map.put(context, :project, project)
  end

  setup :setup_project

  defp path(project), do: "/app/projects/#{project.id}/agent-conversation"

  defp project_scope(scope, project),
    do: %{scope | active_project: project, active_project_id: project.id}

  defp main_copy(scope, project) do
    scope = %{scope | active_project: project, active_project_id: project.id}

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))

    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/preview-state-#{copy.id}")

    assert copy.main, "the fixture below assumes the project's first rooted copy is main"
    copy
  end

  defp with_preview_url(scope, copy) do
    scope = %{scope | active_project_id: copy.project_id}
    {:ok, instance} = AppInstances.ensure_default(scope, copy)

    {:ok, instance} =
      AppInstances.record_preview_tunnel(scope, instance, %{
        preview_url: "https://preview-#{instance.id}.codemyspec.com",
        preview_tunnel_id: "tun-#{instance.id}",
        preview_tunnel_secret: "shh"
      })

    instance
  end

  # The preview tab starts closed for a scope that has never opened it —
  # `stored_panels/1` defaults to `[]` — so every scenario below opens it the
  # same way a person would, rather than asserting against a panel nothing
  # ever displayed.
  defp open_preview(view) do
    view |> element("[data-test='panel-tab-preview']") |> render_click()
  end

  test "a url that has never been health-checked reads as starting, not running", %{
    conn: conn,
    scope: scope,
    project: project
  } do
    scoped = project_scope(scope, project)
    copy = main_copy(scoped, project)
    with_preview_url(scoped, copy)

    {:ok, view, _html} = live(conn, path(project))
    html = open_preview(view)

    assert html =~ ~s(data-test="preview-starting"), """
    A preview url with no `preview_status` yet rendered as `:running` — the
    exact gap that framed a not-yet-connected tunnel and showed its error
    page as if it were the app's own.
    """

    refute html =~ ~s(data-test="preview-frame"),
           "an unprobed url must not be framed yet — that is what shows Cloudflare's own error"
  end

  test "a url the checkout reports serving reads as running", %{
    conn: conn,
    scope: scope,
    project: project
  } do
    scope = project_scope(scope, project)
    instance = scope |> main_copy(project) |> then(&with_preview_url(scope, &1))
    {:ok, _instance} = AppInstances.record_preview_status(scope, instance, "serving")

    {:ok, view, _html} = live(conn, path(project))
    html = open_preview(view)

    assert html =~ ~s(data-test="preview-frame")
  end

  test "a url the checkout reports down reads as down, not running", %{
    conn: conn,
    scope: scope,
    project: project
  } do
    scope = project_scope(scope, project)
    instance = scope |> main_copy(project) |> then(&with_preview_url(scope, &1))
    {:ok, _instance} = AppInstances.record_preview_status(scope, instance, "down")

    {:ok, view, _html} = live(conn, path(project))
    html = open_preview(view)

    assert html =~ ~s(data-test="preview-down")
    refute html =~ ~s(data-test="preview-frame")
  end

  test "a url the checkout reports erroring reads as broken, not running", %{
    conn: conn,
    scope: scope,
    project: project
  } do
    scope = project_scope(scope, project)
    instance = scope |> main_copy(project) |> then(&with_preview_url(scope, &1))
    {:ok, _instance} = AppInstances.record_preview_status(scope, instance, "erroring")

    {:ok, view, _html} = live(conn, path(project))
    html = open_preview(view)

    assert html =~ ~s(data-test="preview-broken")
    refute html =~ ~s(data-test="preview-frame")
  end

  test "no main checkout at all is still absent, not starting", %{
    conn: conn,
    project: project
  } do
    {:ok, _view, html} = live(conn, path(project))

    refute html =~ ~s(data-test="preview-starting"),
           "a project with nothing to preview must not read as one that is merely slow"
  end
end
