defmodule CodeMySpecWeb.PageControllerTest do
  use CodeMySpecTest.ConnCase

  test "GET / renders the marketing home page", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    # Hero copy from the current home.html.heex (post-2026-05-20 single-product CMS focus).
    assert body =~ "Ship with Claude Code"
    assert body =~ "Hold the codebase together"
    assert body =~ "harness layer for engineers shipping with Claude Code"
  end

  test "home page links to the install section", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    assert body =~ ~s|href="#install-section"|
  end

  test "GET /products/market-my-spec 301-redirects to marketmyspec.com", %{conn: conn} do
    conn = get(conn, ~p"/products/market-my-spec")

    assert redirected_to(conn, 301) == "https://marketmyspec.com"
  end
end
