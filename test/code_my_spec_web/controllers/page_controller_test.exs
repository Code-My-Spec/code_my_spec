defmodule CodeMySpecWeb.PageControllerTest do
  use CodeMySpecTest.ConnCase

  test "GET / renders the marketing home page", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    # Hero copy from the current home.html.heex (2026-07 "thinking vs labor" hero).
    assert body =~ "You do the thinking."
    assert body =~ "The machine does the labor."
    # Meta description leads with the canonical quotable definition (GEO).
    assert body =~ "CodeMySpec is a set of AI harnesses that help one person build, sell"
  end

  test "GET /pricing renders the FAQ and references the canonical software entity", %{conn: conn} do
    conn = get(conn, ~p"/pricing")
    body = html_response(conn, 200)

    assert body =~ "How much does CodeMySpec cost?"
    assert body =~ "What happens if I stop paying?"
    assert body =~ ~s|"@type":"FAQPage"|
    # Pricing references the homepage's canonical SoftwareApplication by @id
    # instead of defining a duplicate entity.
    assert body =~ ~s|/#software|
    refute body =~ "model harnesses"
  end

  test "GET / renders the FAQ section with matching FAQPage schema", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    assert body =~ "What is CodeMySpec?"
    assert body =~ "Do I need to know how to code?"
    # Schema and visible content come from the same @home_faqs source.
    assert body =~ ~s|"@type":"FAQPage"|
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
