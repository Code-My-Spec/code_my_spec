defmodule CodeMySpecWeb.IntakeLive.PlanTest do
  use CodeMySpecTest.ConnCase, async: true

  import CodeMySpecSpex.IntakeSteps

  import Phoenix.LiveViewTest

  alias CodeMySpec.Intake

  describe "before any account exists" do
    test "a visitor describes an idea and gets a plan back without signing in", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/build")

      assert html =~ "What do you want to build?"

      html =
        view
        |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
        |> render_submit()

      # A question a person would ask. Sign-in and tenancy are our questions,
      # not the visitor's — they get inferred from the answer, never put.
      assert html =~ "Who&#39;s going to be using this"
      refute html =~ "sign in to use this"
      refute html =~ "separate businesses each use their own copy"

      html =
        view
        |> answer_shaping_questions()

      assert html =~ "Here&#39;s what I think you&#39;re building."
      assert html =~ "salon owners"
    end

    test "the plan states its inferences rather than applying them silently", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build")

      view
      |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
      |> render_submit()

      html =
        view
        |> answer_shaping_questions()

      assert html =~ "People sign in to use it."
      assert html =~ "Everyone shares the one set of data."
      assert html =~ "Account name"
      assert html =~ "Project name"
    end

    test "the questions avoid product jargon", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build")

      html =
        view
        |> form("form[phx-submit=describe]", %{description: "a booking tool"})
        |> render_submit()

      refute html =~ ~r/multi-?tenan/i
      refute html =~ ~r/authentication/i
    end
  end

  describe "coming back" do
    test "the same browser session lands on the plan it left", %{conn: conn} do
      # Establish the session cookie first; subsequent requests on this conn
      # recycle it, which is what makes this a return visit rather than a new one.
      conn = get(conn, ~p"/build")
      {:ok, view, _html} = live(conn)

      view
      |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
      |> render_submit()

      view
      |> answer_shaping_questions()

      # A fresh mount on the same session — as if they closed the tab and came back.
      {:ok, _view, html} = live(conn, ~p"/build")

      assert html =~ "Here&#39;s what I think you&#39;re building."
      assert html =~ "salon owners"
    end

    test "a different browser gets a fresh start rather than an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/build")

      view
      |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
      |> render_submit()

      {:ok, _view, html} = live(build_conn(), ~p"/build")

      assert html =~ "What do you want to build?"
    end
  end

  describe "confirming names" do
    test "a correction is what survives to the gate", %{conn: conn} do
      conn = get(conn, ~p"/build")
      {:ok, view, _html} = live(conn)

      view
      |> form("form[phx-submit=describe]", %{description: "a booking tool for hair salons"})
      |> render_submit()

      view
      |> answer_shaping_questions()

      token = get_session(conn, "intake_token")

      assert {:error, {:live_redirect, %{to: "/users/register"}}} =
               view
               |> form("form[phx-submit=confirm_names]", %{
                 plan: %{account_name: "Acme", project_name: "Widget Tracker"}
               })
               |> render_submit()

      plan = Intake.get_plan(token)
      assert plan.account_name == "Acme"
      assert plan.project_name == "Widget Tracker"
    end
  end
end
