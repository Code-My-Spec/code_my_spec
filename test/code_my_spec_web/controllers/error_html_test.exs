defmodule CodeMySpecWeb.ErrorHTMLTest do
  use CodeMySpecTest.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders branded 404.html with recovery links" do
    html = render_to_string(CodeMySpecWeb.ErrorHTML, "404", "html", [])
    assert html =~ "This page doesn't exist."
    assert html =~ ~s(href="/blog")
    assert html =~ ~s(href="/pricing")
    assert html =~ ~s(href="/documentation")
  end

  test "renders 500.html" do
    assert render_to_string(CodeMySpecWeb.ErrorHTML, "500", "html", []) == "Internal Server Error"
  end
end
