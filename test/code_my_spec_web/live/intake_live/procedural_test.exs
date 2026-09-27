defmodule CodeMySpecWeb.IntakeLive.ProceduralTest do
  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpec.Intake

  @attrs %{
    account_name: "Acme",
    project_name: "Widget Tracker",
    who_uses: "warehouse staff",
    needs_sign_in: "true",
    separate_copies: "false",
    technical: "false"
  }

  defp submit_details(view, attrs \\ @attrs) do
    view
    |> form("form[phx-submit=submit]", %{plan: attrs})
    |> render_submit()
  end

  defp confirm_tier(view, location) do
    view
    |> form("form[phx-submit=confirm_tier]", %{plan: %{location: location}})
    |> render_submit()
  end

  defp back(view, to) do
    view
    |> element("button[phx-click=back][phx-value-to=#{to}]")
    |> render_click()
  end

  describe "before any account exists" do
    test "offers a reset back to the root, for testing", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/build/procedural")

      assert html =~ "Reset"
      assert has_element?(view, "form[action='/build/reset']")
    end

    test "filling the details form in shows a priced tier next, not signup yet", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build/procedural")

      html = submit_details(view)

      refute html =~ "One more thing, and we can start building.",
             "location has not been confirmed yet — the tier is a separate step"

      assert html =~ "$100/month"
      assert html =~ "$25/month"
    end

    test "a non-technical visitor is suggested cloud", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build/procedural")

      html = submit_details(view, Map.put(@attrs, :technical, "false"))

      assert has_element?(view, "input[value='cloud'][checked]")
      refute has_element?(view, "input[value='local'][checked]")
      assert html =~ "Cloud"
    end

    test "a technical visitor is suggested dev local", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build/procedural")

      submit_details(view, Map.put(@attrs, :technical, "true"))

      assert has_element?(view, "input[value='local'][checked]")
      refute has_element?(view, "input[value='cloud'][checked]")
    end

    test "confirming the tier reaches a plan with no conversation involved", %{conn: conn} do
      conn = get(conn, ~p"/build/procedural")
      {:ok, view, _html} = live(conn)

      submit_details(view)
      html = confirm_tier(view, "local")

      # Anonymous, so this lands the visitor on the sign-up card in the same
      # page rather than redirecting — the same gate `IntakeLive.Plan` uses.
      assert html =~ "One more thing, and we can start building."
      assert html =~ "Acme"
      assert html =~ "Widget Tracker"

      token = get_session(conn, "intake_token")
      plan = Intake.get_plan(token)

      assert plan.status == :planned
      assert plan.procedural == true
      assert plan.who_uses == "warehouse staff"
      assert plan.technical == false
      assert plan.location == :local
      assert plan.shaping_turns == [], "the form filled this in, not a model call"
    end

    test "a blank required field stays on the details form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build/procedural")

      html = submit_details(view, Map.put(@attrs, :account_name, ""))

      assert html =~ "can&#39;t be blank"
      refute html =~ "$100/month"
    end
  end

  describe "back" do
    test "from pricing returns to the details form, values still filled in", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build/procedural")

      submit_details(view)
      html = back(view, "details")

      assert has_element?(view, "input[name='plan[account_name]'][value='Acme']")
      refute html =~ "$100/month"
    end

    test "writes nothing — the plan still has what was already confirmed", %{conn: conn} do
      conn = get(conn, ~p"/build/procedural")
      {:ok, view, _html} = live(conn)

      submit_details(view)
      back(view, "details")

      token = get_session(conn, "intake_token")
      plan = Intake.get_plan(token)

      assert plan.status == :planned, "going back does not un-submit the details step"
      assert plan.account_name == "Acme"
    end

    test "from signup returns to pricing, the confirmed tier still pre-selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build/procedural")

      submit_details(view)
      confirm_tier(view, "local")
      html = back(view, "pricing")

      refute html =~ "One more thing, and we can start building."
      assert has_element?(view, "input[value='local'][checked]")
    end

    test "forward again after going back reaches the same place", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build/procedural")

      submit_details(view)
      back(view, "details")
      submit_details(view)
      html = confirm_tier(view, "cloud")

      assert html =~ "One more thing, and we can start building."
    end
  end

  describe "already signed in" do
    setup :register_log_in_setup_account

    test "confirming the tier goes straight to the workspace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build/procedural")

      submit_details(view)

      assert {:error, {:live_redirect, %{to: to}}} = confirm_tier(view, "cloud")
      assert to == "/build/workspace"
    end
  end
end
