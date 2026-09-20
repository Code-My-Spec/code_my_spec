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
    location: "cloud"
  }

  describe "before any account exists" do
    test "filling the form in reaches a plan with no conversation involved", %{conn: conn} do
      conn = get(conn, ~p"/build/procedural")
      {:ok, view, _html} = live(conn)

      html =
        view
        |> form("form[phx-submit=submit]", %{plan: @attrs})
        |> render_submit()

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
      assert plan.shaping_turns == [], "the form filled this in, not a model call"
    end

    test "a blank required field stays on the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build/procedural")

      html =
        view
        |> form("form[phx-submit=submit]", %{plan: Map.put(@attrs, :account_name, "")})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute html =~ "One more thing, and we can start building."
    end
  end

  describe "already signed in" do
    setup :register_log_in_setup_account

    test "filling the form in goes straight to the workspace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build/procedural")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("form[phx-submit=submit]", %{plan: @attrs})
               |> render_submit()

      assert to == "/build/workspace"
    end
  end
end
