defmodule CodeMySpecWeb.PageControllerTest do
  use CodeMySpecTest.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Keep your architecture."
  end

  test "primary CTA points unauthenticated visitors to registration", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    assert body =~ "Get started free"
    assert body =~ ~s|href="/users/register"|
    refute body =~ "Open the workspace"
  end
end
