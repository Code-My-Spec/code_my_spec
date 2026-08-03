defmodule CodeMySpecWeb.IntakeLive.WorkspaceTest do
  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.{Events, Workspaces}
  alias CodeMySpecTest.FakeWorkspaceRunner

  setup %{conn: conn} do
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces,
      runner: FakeWorkspaceRunner,
      boot_timeout: 200,
      poll_interval: 20
    )

    on_exit(&stop_watchers/0)

    %{conn: log_in_user(conn, user_fixture())}
  end

  defp fake(opts), do: start_supervised!({FakeWorkspaceRunner, opts})

  # Kill every watcher before clearing the config, in that order. A watcher
  # that outlives its test falls back to the default runner — which is the
  # real Docker one — and polls it for the default fifteen minutes, dragging
  # the rest of the suite with it.
  defp stop_watchers do
    CodeMySpec.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.each(&Process.exit(&1, :kill))

    Application.delete_env(:code_my_spec, CodeMySpec.Workspaces)
  end

  # A boot that will not time out on its own. Tests that need to observe the
  # booting state end it explicitly with finish_boot/0 rather than racing the
  # watcher's deadline — under load the test loses that race.
  defp never_times_out do
    config = Application.get_env(:code_my_spec, CodeMySpec.Workspaces)
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces, put_in(config[:boot_timeout], 60_000))
  end

  # Lets the instance start answering, so the watcher completes and stops.
  defp finish_boot do
    FakeWorkspaceRunner.put_healthy(true)
    settle()
  end

  # Walks the visitor through the pre-gate flow so a confirmed plan exists on
  # this session, which is what the workspace screen converts.
  defp with_confirmed_plan(conn) do
    conn = get(conn, ~p"/build")
    {:ok, view, _html} = live(conn)

    view
    |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
    |> render_submit()

    view
    |> form("form[phx-submit=answer]", %{
      plan: %{needs_sign_in: "true", separate_copies: "true", who_uses: "salon owners"}
    })
    |> render_submit()

    view
    |> form("form[phx-submit=confirm_names]", %{
      plan: %{account_name: "Acme", project_name: "Widget Tracker"}
    })
    |> render_submit()

    conn
  end

  describe "coming up" do
    test "the visitor sees a progress bar driven by the container's own phases", %{conn: conn} do
      fake(healthy?: false, alive?: true, logs: "\e[1;36m==> Fetching dependencies\e[0m")
      never_times_out()
      conn = with_confirmed_plan(conn)

      {:ok, view, html} = live(conn, ~p"/build/workspace")

      assert html =~ "Now let's decide what it actually does." or html =~ "decide what it actually does"
      assert render_async_progress(view) =~ "Fetching dependencies"

      finish_boot()
    end

    test "the running application is offered to look at", %{conn: conn} do
      fake(healthy?: true)
      conn = with_confirmed_plan(conn)

      {:ok, view, _html} = live(conn, ~p"/build/workspace")

      html = eventually(view, "It&#39;s running.")

      assert html =~ "Open your application"
      assert html =~ "http://localhost:"
      # The interview is the foreground even once it is up.
      assert html =~ "decide what it actually does"
    end
  end

  describe "when it does not come up" do
    test "the visitor is told, and the plan is still there", %{conn: conn} do
      fake(healthy?: false, alive?: false)
      conn = with_confirmed_plan(conn)

      {:ok, view, _html} = live(conn, ~p"/build/workspace")

      html = eventually(view, "didn&#39;t come up")

      assert html =~ "stopped before it finished starting up"
      assert html =~ "Your plan is safe"
      assert html =~ "Try again"
    end
  end

  describe "dropping out" do
    test "leaving mid-boot is recorded with the phase they left on", %{conn: conn} do
      fake(healthy?: false, alive?: true, logs: "\e[1;36m==> Fetching dependencies\e[0m")
      never_times_out()
      conn = with_confirmed_plan(conn)

      {:ok, view, _html} = live(conn, ~p"/build/workspace")
      eventually(view, "Fetching dependencies")

      # The visitor closes the tab while it is still coming up.
      ref = Process.monitor(view.pid)
      GenServer.stop(view.pid, :normal)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1_000

      assert eventually_recorded("workspace_abandoned")

      # The visitor left, but the watcher is still going. End it here rather
      # than letting it outlive the sandbox it writes to.
      finish_boot()
    end

    test "staying until it is up is not an abandonment", %{conn: conn} do
      fake(healthy?: true)
      conn = with_confirmed_plan(conn)

      {:ok, view, _html} = live(conn, ~p"/build/workspace")
      eventually(view, "It&#39;s running.")

      ref = Process.monitor(view.pid)
      GenServer.stop(view.pid, :normal)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1_000

      assert eventually_recorded("workspace_running")
      refute Events.exists?("workspace_abandoned")
    end
  end

  describe "with no plan on this session" do
    test "the visitor is sent to the front of the flow", %{conn: conn} do
      fake(healthy?: true)

      assert {:error, {:live_redirect, %{to: "/build"}}} = live(conn, ~p"/build/workspace")
    end
  end

  describe "the account and project the plan named" do
    test "become the visitor's active ones", %{conn: conn} do
      fake(healthy?: true)
      conn = with_confirmed_plan(conn)

      {:ok, view, _html} = live(conn, ~p"/build/workspace")
      eventually(view, "It&#39;s running.")

      scope = :sys.get_state(view.pid).socket.assigns.scope

      assert scope.active_account.name == "Acme"
      assert scope.active_project.name == "Widget Tracker"
      assert Workspaces.get_workspace(scope).status == :running
    end
  end

  defp render_async_progress(view), do: eventually(view, "Fetching dependencies")

  # Waits until no workspace is still booting, i.e. every watcher task has
  # finished. Without this a test can end while a task is mid-poll, and the
  # task then writes to a sandbox that has already been rolled back.
  defp settle(attempts \\ 250)

  defp settle(0), do: :ok

  defp settle(attempts) do
    case CodeMySpec.Repo.all(Workspaces.Workspace) do
      [] ->
        :ok

      workspaces ->
        case Enum.any?(workspaces, &(&1.status == :booting)) do
          false ->
            :ok

          true ->
            Process.sleep(20)
            settle(attempts - 1)
        end
    end
  end

  # Transitions record their event and then broadcast, and the screen can also
  # read the new status straight from the row — so a render can legitimately
  # win the race against the write. Wait for the write itself.
  defp eventually_recorded(event_type, attempts \\ 250)

  defp eventually_recorded(_event_type, 0), do: false

  defp eventually_recorded(event_type, attempts) do
    case Events.exists?(event_type) do
      true ->
        true

      false ->
        Process.sleep(20)
        eventually_recorded(event_type, attempts - 1)
    end
  end

  # The boot watcher reports by broadcast, so the screen updates a beat after
  # mount rather than during it. The budget is generous because these run
  # alongside the rest of the suite, where scheduling latency is real.
  defp eventually(view, text, attempts \\ 250)

  defp eventually(view, text, 0), do: flunk("never rendered #{inspect(text)}: #{render(view)}")

  defp eventually(view, text, attempts) do
    html = render(view)

    case String.contains?(html, text) do
      true ->
        html

      false ->
        Process.sleep(20)
        eventually(view, text, attempts - 1)
    end
  end
end
