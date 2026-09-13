defmodule CodeMySpecWeb.IntakeLive.WorkspaceTest do
  # Sync: writes `:code_my_spec, CodeMySpec.Workspaces`, the same key
  # `CodeMySpec.WorkspacesTest` writes, to install the fake runner. See that file
  # for what moving it would take.
  use CodeMySpecTest.ConnCase, async: false

  import CodeMySpecSpex.IntakeSteps

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

    # Kills this test's watchers before clearing the config, in that order.
    # A watcher that outlives its test falls back to the default runner —
    # which is the real Docker one — and polls it for fifteen minutes,
    # dragging the rest of the suite with it.
    CodeMySpecTest.WorkspaceWatchers.reset_on_exit()

    stub_stripe()

    %{conn: log_in_user(conn, user_fixture())}
  end

  # Cloud now pays before it provisions (990/3400). `with_confirmed_plan/1`
  # always ends up cloud (the default location), so every test in this file
  # needs a working Stripe stub to get past `Billing.start_subscription/2` —
  # same shape `CodeMySpec.BillingTest` records by hand.
  defp stub_stripe do
    Application.put_env(:code_my_spec, CodeMySpec.Billing.StripeClient,
      secret_key: "sk_test_workspace",
      plug: {Req.Test, CodeMySpec.Billing.StripeClient}
    )

    Application.put_env(:code_my_spec, CodeMySpec.Billing,
      webhook_secret: "whsec_workspace",
      light_price_id: "price_light_workspace",
      pro_price_id: "price_pro_workspace"
    )

    Req.Test.stub(CodeMySpec.Billing.StripeClient, &stripe_response/1)

    on_exit(fn ->
      Application.delete_env(:code_my_spec, CodeMySpec.Billing.StripeClient)
      Application.delete_env(:code_my_spec, CodeMySpec.Billing)
    end)
  end

  defp stripe_response(%{request_path: "/v1/customers"} = conn) do
    Plug.Conn.put_resp_content_type(conn, "application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "cus_workspace"}))
  end

  defp stripe_response(%{request_path: "/v1/subscriptions"} = conn) do
    body = %{
      "id" => "sub_workspace",
      "latest_invoice" => %{
        "confirmation_secret" => %{"client_secret" => "pi_workspace_secret"}
      }
    }

    Plug.Conn.put_resp_content_type(conn, "application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  # Clears the payment step the way the browser's own Stripe hook would, so
  # a test not about payment can reach the workspace it actually needs.
  defp pay(view), do: render_hook(view, "payment_confirmed", %{})

  defp fake(opts), do: start_supervised!({FakeWorkspaceRunner, opts})

  # A boot that will not time out on its own. Tests that need to observe the
  # booting state end it explicitly with finish_boot/0 rather than racing the
  # watcher's deadline — under load the test loses that race.
  defp never_times_out do
    config = Application.get_env(:code_my_spec, CodeMySpec.Workspaces)

    Application.put_env(
      :code_my_spec,
      CodeMySpec.Workspaces,
      put_in(config[:boot_timeout], 60_000)
    )
  end

  # Lets the instance start answering, so the watcher completes and stops.
  defp finish_boot do
    FakeWorkspaceRunner.put_healthy(true)
    settle()
  end

  # Walks the visitor through the pre-gate flow so a confirmed plan exists on
  # this session, which is what the workspace screen converts.
  defp with_confirmed_plan(conn, plan \\ %{}) do
    conn = get(conn, ~p"/build")
    {:ok, view, _html} = live(conn)

    view
    |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
    |> render_submit()

    view
    |> answer_shaping_questions()

    view
    |> form("form[phx-submit=confirm_names]", %{
      plan: Map.merge(%{account_name: "Acme", project_name: "Widget Tracker"}, plan)
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

      # The conversation, not a new heading. This page used to open with "Now
      # let's decide what it actually does" over a card-based interview, so a
      # visitor who had just confirmed a plan arrived somewhere that looked like
      # a different product. Signup navigates between the two pages, so the
      # transcript is rebuilt from the plan row rather than carried.
      assert html =~ "What do you want to build?",
             "the workspace page does not show what was said before it existed, so " <>
               "the visitor's conversation restarts at the signup gate"

      assert html =~ "a booking tool for hair salons"

      pay(view)
      assert render_async_progress(view) =~ "Fetching dependencies"

      finish_boot()
    end

    test "the running application is offered to look at", %{conn: conn} do
      fake(healthy?: true)
      conn = with_confirmed_plan(conn)

      {:ok, view, _html} = live(conn, ~p"/build/workspace")
      pay(view)

      html = eventually(view, "It&#39;s running.")

      assert html =~ "Open your application"
      assert html =~ "http://localhost:"
      # The conversation is the foreground even once it is up — the boot is
      # ambient, which is the whole reason the interview runs during it.
      assert html =~ "What do you want to build?"
    end
  end

  describe "when it does not come up" do
    test "the visitor is told, and the plan is still there", %{conn: conn} do
      fake(healthy?: false, alive?: false)
      conn = with_confirmed_plan(conn)

      {:ok, view, _html} = live(conn, ~p"/build/workspace")
      pay(view)

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
      pay(view)
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

    test "leaving before paying does not crash the termination", %{conn: conn} do
      fake(healthy?: false, alive?: true)
      conn = with_confirmed_plan(conn)

      {:ok, view, _html} = live(conn, ~p"/build/workspace")

      # No `pay(view)` here — `@workspace` is still the `%{status:
      # :awaiting_payment}` placeholder assigned before a real `%Workspace{}`
      # row exists (69a1ff70 follow-up: `Workspaces.abandoned/1` only matches
      # `%Workspace{}`, so terminating on the placeholder used to crash with
      # a FunctionClauseError instead of quietly doing nothing).
      ref = Process.monitor(view.pid)
      GenServer.stop(view.pid, :normal)
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 1_000
    end

    test "staying until it is up is not an abandonment", %{conn: conn} do
      fake(healthy?: true)
      conn = with_confirmed_plan(conn)

      {:ok, view, _html} = live(conn, ~p"/build/workspace")
      pay(view)
      eventually(view, "It&#39;s running.")

      ref = Process.monitor(view.pid)
      GenServer.stop(view.pid, :normal)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1_000

      assert eventually_recorded("workspace_running")
      refute Events.exists?("workspace_abandoned")
    end
  end

  # Two mount paths put a workspace-shaped map on the socket rather than a row,
  # and leaving on either of them used to crash terminate/2 (f96f17a0). Nothing
  # the visitor sees — the socket has already gone — but it is reachable by
  # anybody who closes the tab during the payment window, and the crash report
  # buried a real boot failure in the same log.
  describe "leaving before a workspace exists" do
    test "during the payment step is not a crash", %{conn: conn} do
      fake(healthy?: true)
      conn = with_confirmed_plan(conn)

      {:ok, view, html} = live(conn, ~p"/build/workspace")

      assert html =~ "Pay",
             "the premise failed: this test needs the socket parked on the payment step, " <>
               "with no workspace row yet"

      assert :ok = GenServer.stop(view.pid, :normal)
      refute Events.exists?("workspace_abandoned")
    end

    test "on the local path is not a crash either", %{conn: conn} do
      fake(healthy?: true)
      conn = with_confirmed_plan(conn, %{location: "local"})

      {:ok, view, html} = live(conn, ~p"/build/workspace")

      assert html =~ "mix cms.new",
             "the premise failed: this test needs the local branch, which provisions " <>
               "nothing and so never has a workspace row"

      assert :ok = GenServer.stop(view.pid, :normal)
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
      pay(view)
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
    booting? = Enum.any?(CodeMySpec.Repo.all(Workspaces.Workspace), &(&1.status == :booting))
    settle_booting(booting?, attempts)
  end

  defp settle_booting(false, _attempts), do: :ok

  defp settle_booting(true, attempts) do
    Process.sleep(20)
    settle(attempts - 1)
  end

  # Transitions record their event and then broadcast, and the screen can also
  # read the new status straight from the row — so a render can legitimately
  # win the race against the write. Wait for the write itself.
  defp eventually_recorded(event_type, attempts \\ 250)

  defp eventually_recorded(_event_type, 0), do: false

  defp eventually_recorded(event_type, attempts) do
    recorded(Events.exists?(event_type), event_type, attempts)
  end

  defp recorded(true, _event_type, _attempts), do: true

  defp recorded(false, event_type, attempts) do
    Process.sleep(20)
    eventually_recorded(event_type, attempts - 1)
  end

  # The boot watcher reports by broadcast, so the screen updates a beat after
  # mount rather than during it. The budget is generous because these run
  # alongside the rest of the suite, where scheduling latency is real.
  defp eventually(view, text, attempts \\ 250)

  defp eventually(view, text, 0), do: flunk("never rendered #{inspect(text)}: #{render(view)}")

  defp eventually(view, text, attempts) do
    html = render(view)
    eventually_rendered(String.contains?(html, text), html, view, text, attempts)
  end

  defp eventually_rendered(true, html, _view, _text, _attempts), do: html

  defp eventually_rendered(false, _html, view, text, attempts) do
    Process.sleep(20)
    eventually(view, text, attempts - 1)
  end
end
