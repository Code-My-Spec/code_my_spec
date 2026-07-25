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

  test "GET /products/code-my-spec 301-redirects to the /product cornerstone", %{conn: conn} do
    conn = get(conn, ~p"/products/code-my-spec")

    assert redirected_to(conn, 301) == "/product"
  end

  test "retired MCP-era feature pages 301 into the cornerstone", %{conn: conn} do
    for slug <- ~w(architect-mcp-feature design-documentation-feature
                   product-manager-mcp-feature stories-feature stories-mcp-server) do
      conn = get(build_conn(), "/pages/#{slug}")

      assert redirected_to(conn, 301) == "/product",
             "expected /pages/#{slug} to 301 to /product"
    end

    # The plug must not hijack page slugs it wasn't given. (Content lives in the
    # database, which is empty here, so the live page 404s in test — the point is
    # that it falls through to the controller instead of redirecting.)
    refute get(conn, ~p"/pages/about").status == 301
  end

  test "marketing pages are reachable from the shared nav, not just by URL", %{conn: conn} do
    body = get(conn, ~p"/") |> html_response(200)

    # A page nobody can navigate to is a page nobody reads. Any new marketing
    # route belongs in the navbar, the mobile drawer, or the footer.
    for path <- ~w(/product /developers /agents /install /methodology /pricing /blog /documentation) do
      assert body =~ ~s|href="#{path}"|, "expected #{path} to be linked from the layout"
    end
  end

  test "GET /product renders the cornerstone with a liftable definition", %{conn: conn} do
    conn = get(conn, ~p"/product")
    body = html_response(conn, 200)

    # Leads with the problem the reader has actually lived, not the product
    # category. /developers is the engineer-pitched page; this one is not.
    assert body =~ "Then you change one thing, and it falls down."
    assert body =~ "CodeMySpec is for the morning after."
    assert body =~ "supervise it. The harness supervises it."
  end

  test "GET /product stays legible to a non-engineer", %{conn: conn} do
    conn = get(conn, ~p"/product")
    body = html_response(conn, 200)

    # Engineers are not the audience here — the tool names belong on /developers.
    # The claims stay; the jargon goes. Scoped to visible copy: the JSON-LD
    # featureList keeps precise tool names on purpose, because that is read by
    # machines answering capability questions and never by a human on the page.
    visible = String.replace(body, ~r|<script type="application/ld\+json".*?</script>|s, "")

    for jargon <- ~w(Credo ExUnit OTP GenServer LiveView) do
      refute visible =~ jargon, "expected /product copy to avoid #{jargon}"
    end

    # The workday rhythm is the most persuasive thing available to this reader.
    assert body =~ "A workday with a beginning and an end."
    assert body =~ "Overnight"
  end

  test "GET /product leads on executable specs, not written spec documents", %{conn: conn} do
    conn = get(conn, ~p"/product")
    body = html_response(conn, 200)

    # The executable BDD specs are the core innovation and the only mandatory
    # spec layer. The written module spec is a config knob (require_specs) that
    # real projects turn off, so the copy must not present markdown documents as
    # the artifact you get.
    assert body =~ "the BDD specs are the walls"
    # Stated in plain language rather than as "the specifications execute" — same
    # claim, legible to a reader who will never open the repo.
    assert body =~ "becomes a test that uses your application the way a person would"
    refute body =~ "plain markdown"
    refute body =~ "specs are markdown"
  end

  test "GET /product shows a readable scenario, never a code sample", %{conn: conn} do
    conn = get(conn, ~p"/product")
    body = html_response(conn, 200)

    # A product page sells the idea; a wall of Elixir screens out everyone not
    # already deep in the language. The scenario is the readable half of an
    # executable spec, so it carries the point in plain language instead.
    assert body =~ "an active card"
    assert body =~ "the next swipe is declined"
    assert body =~ "Verified against your code"

    refute body =~ "<pre"
    refute body =~ "defmodule"
    # Slash commands are the product's own vocabulary and stay; source is out.
    refute body =~ "assert "
  end

  test "GET /product carries FAQ, software and breadcrumb schema", %{conn: conn} do
    conn = get(conn, ~p"/product")
    body = html_response(conn, 200)

    assert body =~ ~s|"@type":"FAQPage"|
    assert body =~ ~s|"@type":"SoftwareApplication"|
    assert body =~ ~s|"@type":"BreadcrumbList"|
    # Schema and visible copy come from the same @product_faqs source.
    assert body =~ "Does CodeMySpec lock me in?"
  end

  test "GET /product diagrams are labelled for screen readers", %{conn: conn} do
    conn = get(conn, ~p"/product")
    body = html_response(conn, 200)

    assert body =~ ~s|role="img"|
    assert body =~ "The CodeMySpec process"
    assert body =~ "Where CodeMySpec sits in your toolchain"
  end

  test "GET /agents names the flagship and never claims parity", %{conn: conn} do
    conn = get(conn, ~p"/agents")
    body = html_response(conn, 200)

    assert body =~ "Works with the agent"
    assert body =~ "Claude Code"
    assert body =~ "OpenAI Codex"
    assert body =~ "Google Antigravity"
    # Maturity tiers are load-bearing: one flagship, two early.
    assert body =~ "flagship"
    assert body =~ "early"
    assert body =~ ~s|"@type":"FAQPage"|
  end

  test "GET /agents publishes no unverified install commands", %{conn: conn} do
    conn = get(conn, ~p"/agents")
    body = html_response(conn, 200)

    # The Codex and Antigravity marketplace invocations are flagged unverified in
    # their plugin READMEs. An install command that dead-ends costs more trust
    # than the page earns, so /install owns them and this page only links there.
    refute body =~ "codex plugin marketplace"
    refute body =~ "agy plugin install"
    assert body =~ ~s|href="/install"|
  end

  test "GET /product keeps claims inside the honesty ledger", %{conn: conn} do
    conn = get(conn, ~p"/product")
    body = html_response(conn, 200)

    # Claude Code is the flagship; Codex and Antigravity are early. Never parity.
    assert body =~ "Claude Code has the " <> "deepest integration and is the flagship"
    # The server ships for macOS and Windows only — no Linux binary to promise.
    refute body =~ "Linux"
  end
end
