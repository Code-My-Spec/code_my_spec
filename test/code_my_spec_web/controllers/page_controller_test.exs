defmodule CodeMySpecWeb.PageControllerTest do
  use CodeMySpecTest.ConnCase

  test "GET / renders the marketing home page", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    # Hero copy from the current home.html.heex (2026-07 "thinking vs labor" hero).
    assert body =~ "You do the thinking."
    assert body =~ "The machine does the labor."
    assert body =~ "the work of a whole team, without being one"
  end

  test "home page CTAs link to the install page", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    assert body =~ ~s|href="/install"|
    assert body =~ "Start free"
  end

  test "GET /products/market-my-spec 301-redirects to marketmyspec.com", %{conn: conn} do
    conn = get(conn, ~p"/products/market-my-spec")

    assert redirected_to(conn, 301) == "https://marketmyspec.com"
  end

  test "GET /products/code-my-spec 301-redirects to /developers", %{conn: conn} do
    conn = get(conn, ~p"/products/code-my-spec")

    assert redirected_to(conn, 301) == "/developers"
  end
end
