defmodule CodeMySpecWeb.PageControllerTest do
  use CodeMySpecTest.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Keep your architecture."
  end
end
