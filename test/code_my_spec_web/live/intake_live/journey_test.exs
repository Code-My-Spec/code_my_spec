defmodule CodeMySpecWeb.IntakeLive.JourneyTest do
  @moduledoc """
  One connected walk of the whole intake path, front to back, per tier and
  per entry point — not a substitute for the criterion-level spex (each of
  those pins one behaviour in isolation) but a fast, deterministic check
  that every phase still hands off to the next one correctly: details,
  pricing, a trial or a cloud payment, the interview, and what each tier
  actually lands on afterward.

  Meant to run before a live QA pass, not instead of one: this proves the
  wiring holds end to end; only a browser proves the experience is any
  good. Cheap enough to run on every change, unlike a full manual or
  agent-driven walkthrough.
  """

  use CodeMySpecTest.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodeMySpec.UsersFixtures
  import CodeMySpecSpex.IntakeSteps, only: [describe_idea: 2, answer_shaping_questions: 1]

  alias CodeMySpec.Intake.Interview
  alias CodeMySpec.Workspaces
  alias CodeMySpecTest.FakeWorkspaceRunner

  @question_form "form[phx-submit=answer]"

  setup %{conn: conn} do
    Application.put_env(:code_my_spec, CodeMySpec.Workspaces,
      runner: FakeWorkspaceRunner,
      boot_timeout: 5_000,
      poll_interval: 20
    )

    CodeMySpecTest.WorkspaceWatchers.reset_on_exit()
    stub_stripe()
    stub_no_preview()

    %{conn: log_in_user(conn, user_fixture())}
  end

  # `instance_env/1` asks `PreviewTunnel.ensure/1` for every boot of a main
  # copy, reaching the `Req.Test`-pinned Cloudflare client the same way
  # `stub_stripe/0` reaches the pinned Stripe one. Nothing in this file is
  # testing preview provisioning, so answer with a plain refusal —
  # `preview_env/1` already treats that as best-effort and drops it.
  defp stub_no_preview do
    Req.Test.stub(CodeMySpec.Workspaces.PreviewTunnel, fn conn ->
      Plug.Conn.put_resp_content_type(conn, "application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"success" => false, "errors" => []}))
    end)
  end

  # Same shape `IntakeLive.WorkspaceTest` records by hand. `config/test.exs`
  # sets `CodeMySpec.Billing`'s price ids/webhook_secret statically so specs
  # can read them without a local override — but several existing test files
  # (`CodeMySpec.BillingTest` among them) still `put_env` + `on_exit
  # delete_env` that same global key, and some of those are `async: true`, so
  # their delete can land mid-test here and answer "no price id configured"
  # for a subscription this test never touched. Setting it locally, every
  # test, closes the race the same way `IntakeLive.WorkspaceTest` already
  # does — restoring it on exit rather than leaving it deleted, so an async
  # test relying on the static default straight afterward is not the next
  # one to lose this race.
  defp stub_stripe do
    original_billing_config = Application.get_env(:code_my_spec, CodeMySpec.Billing, [])

    original_stripe_client_config =
      Application.get_env(:code_my_spec, CodeMySpec.Billing.StripeClient, [])

    Application.put_env(:code_my_spec, CodeMySpec.Billing.StripeClient,
      secret_key: "sk_test_journey",
      plug: {Req.Test, CodeMySpec.Billing.StripeClient}
    )

    Application.put_env(:code_my_spec, CodeMySpec.Billing,
      webhook_secret: "whsec_journey",
      light_price_id: "price_light_journey",
      pro_price_id: "price_pro_journey"
    )

    Req.Test.stub(CodeMySpec.Billing.StripeClient, &stripe_response/1)

    on_exit(fn ->
      Application.put_env(:code_my_spec, CodeMySpec.Billing, original_billing_config)

      Application.put_env(
        :code_my_spec,
        CodeMySpec.Billing.StripeClient,
        original_stripe_client_config
      )
    end)
  end

  defp stripe_response(%{request_path: "/v1/customers"} = conn),
    do: json(conn, %{"id" => "cus_journey"})

  # `status: "trialing"` unconditionally: covers both tiers fine, since
  # `client_secret/1` reads whichever field is present regardless of the
  # tier actually being bought, and neither journey below asserts on the
  # tier-specific price used to create it.
  defp stripe_response(%{request_path: "/v1/subscriptions"} = conn) do
    json(conn, %{
      "id" => "sub_journey",
      "status" => "trialing",
      "latest_invoice" => nil,
      "pending_setup_intent" => %{"client_secret" => "seti_journey_secret"}
    })
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp fake(opts), do: start_supervised!({FakeWorkspaceRunner, opts})

  # Clears the payment step the way the browser's own Stripe hook would.
  defp confirm_payment(view), do: render_hook(view, "payment_confirmed", %{})

  # Answers whatever is on screen until the question form is gone. Bounded
  # by the real cap plus one, so a journey where the interview never pays
  # out fails loudly here instead of looping forever.
  defp answer_all_interview_questions(view) do
    answer_until_done(view, Interview.question_cap() + 1)
  end

  defp answer_until_done(view, 0), do: render(view)

  defp answer_until_done(view, remaining),
    do: answer_if_asked(has_element?(view, @question_form), view, remaining)

  defp answer_if_asked(false, view, _remaining), do: render(view)

  defp answer_if_asked(true, view, remaining) do
    view
    |> form(@question_form, %{answer: "a real answer, in their own words"})
    |> render_submit()

    answer_until_done(view, remaining - 1)
  end

  defp eventually(view, text, attempts \\ 250)

  defp eventually(view, text, 0), do: flunk("never rendered #{inspect(text)}: #{render(view)}")

  defp eventually(view, text, attempts),
    do: eventually_alive(Process.alive?(view.pid), view, text, attempts)

  defp eventually_alive(false, _view, text, _attempts),
    do: flunk("view process died while polling for #{inspect(text)}")

  defp eventually_alive(true, view, text, attempts) do
    html = render(view)
    eventually_rendered(String.contains?(html, text), html, view, text, attempts)
  end

  defp eventually_rendered(true, html, _view, _text, _attempts), do: html

  defp eventually_rendered(false, _html, view, text, attempts) do
    Process.sleep(20)
    eventually(view, text, attempts - 1)
  end

  describe "the procedural path (no conversation)" do
    test "a technical visitor picks the local trial and lands on run-it-yourself instructions",
         %{conn: conn} do
      fake(healthy?: true)

      conn = get(conn, ~p"/build/procedural")
      {:ok, view, _html} = live(conn)

      view
      |> form("form[phx-submit=submit]", %{
        plan: %{
          account_name: "Journey Co",
          project_name: "Journey App",
          who_uses: "warehouse staff",
          needs_sign_in: "true",
          separate_copies: "false",
          technical: "true"
        }
      })
      |> render_submit()

      # Already signed in, so this is a live_redirect straight to the
      # workspace rather than the anonymous sign-up card.
      assert {:error, {:live_redirect, %{to: "/build/workspace"}}} =
               view
               |> form("form[phx-submit=confirm_tier]", %{plan: %{location: "local"}})
               |> render_submit()

      {:ok, view, _html} = live(conn, ~p"/build/workspace")

      # Gated on the trial's card before anything about "run it yourself" shows.
      assert render(view) =~ "7 days free"
      refute render(view) =~ "Waiting for your harness"

      html = confirm_payment(view)
      assert html =~ "Waiting for your harness"

      assert Workspaces.get_workspace(:sys.get_state(view.pid).socket.assigns.scope) == nil,
             "local never provisions a container on the shared host, trial or not"

      answer_all_interview_questions(view)
      assert render(view) =~ "the rules I derived"
    end

    test "a non-technical visitor picks cloud, boots, and is dumped straight into the cockpit",
         %{conn: conn} do
      fake(healthy?: true)

      conn = get(conn, ~p"/build/procedural")
      {:ok, view, _html} = live(conn)

      view
      |> form("form[phx-submit=submit]", %{
        plan: %{
          account_name: "Journey Cloud Co",
          project_name: "Journey Cloud App",
          who_uses: "shift managers",
          needs_sign_in: "true",
          separate_copies: "false",
          technical: "false"
        }
      })
      |> render_submit()

      view
      |> form("form[phx-submit=confirm_tier]", %{plan: %{location: "cloud"}})
      |> render_submit()

      {:ok, view, _html} = live(conn, ~p"/build/workspace")
      project_id = :sys.get_state(view.pid).socket.assigns.scope.active_project_id

      assert render(view) =~ "Running in the cloud is $100/month."

      confirm_payment(view)

      # A procedural plan skips the "It's running" card entirely once the
      # container comes up — `IntakeLive.Workspace.dump_into_cockpit/2` sends
      # it straight to the cockpit instead, same as the chat-based journey
      # below reaches by staying on the card and clicking through.
      assert_redirect(view, ~p"/app/projects/#{project_id}/agent-conversation")
    end
  end

  describe "the agent-assisted path (the conversation)" do
    test "shaping through to a running application, with the interview paying out along the way",
         %{conn: conn} do
      fake(healthy?: true)

      conn = get(conn, ~p"/build")
      {:ok, view, _html} = live(conn)

      describe_idea(view, "a booking tool for hair salons")
      answer_shaping_questions(view)

      view
      |> form("form[phx-submit=confirm_names]", %{
        plan: %{account_name: "Journey Salon Co", project_name: "Journey Booking"}
      })
      |> render_submit()

      {:ok, view, _html} = live(conn, ~p"/build/workspace")

      assert render(view) =~ "a booking tool for hair salons",
             "the workspace page must carry the shaping conversation forward, not restart it"

      confirm_payment(view)

      answer_all_interview_questions(view)
      assert render(view) =~ "the rules I derived"

      html = eventually(view, "It&#39;s running.")
      assert html =~ "Talk to your agent"
    end
  end
end
