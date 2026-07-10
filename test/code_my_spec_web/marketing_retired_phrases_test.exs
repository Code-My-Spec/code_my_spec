defmodule CodeMySpecWeb.MarketingRetiredPhrasesTest do
  @moduledoc """
  Regression-prevention spec: marketing surfaces must not contain any phrase
  from the codemyspec_marketing repo's `marketing/06_messaging.md` "Phrases
  to retire, permanently" list.

  The 2026-05-07 strategy revert pulled codemyspec.com off platform-as-wedge
  framing back to engineer-and-agency framing. A 9-day signup drought was
  partly attributed to copy drift — the marketing-strategy doc was reverted
  but the rendered surfaces still carried 4/27 phrasing. This test is the
  linter that prevents that drift from re-entering the codebase.

  Source of truth: `marketing/06_messaging.md` section "Phrases to retire,
  permanently". Keep the list below in sync. If a phrase is intentionally
  acceptable in user-quoted context (e.g. an FAQ question echoing the
  persona's own words), this test will catch it — that's a feature, not a
  bug. Decide on rewrite or carve-out with the marketing doc as arbiter.
  """

  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpecWeb.Layouts

  # Phrases verbatim from marketing/06_messaging.md "Phrases to retire,
  # permanently" plus close paraphrases that the 5/19 audit caught
  # appearing on rendered surfaces (Story D in
  # signup-funnel-leak-and-release-crash.md).
  @retired_phrases [
    # Verbatim from 06_messaging.md "Phrases to retire, permanently"
    "Lights out software factory",
    "10x your velocity",
    "Replace your developers",
    "Any 8-year-old can build a Harry Potter game",
    "Next-gen AI-powered development",
    "Revolutionize your workflow",
    "AI marketing automation",
    "Mentioning my stack is a total disqualifier",
    "Run your business — marketing, engineering, ops — from one terminal",
    "Platform of harnesses for the founder doing every job",
    # Close paraphrases of the retired 4/27 platform-as-wedge hero that
    # actually shipped on surfaces (the 5/19 audit caught these on / and
    # /users/register).
    "Run your entire software business",
    "founder doing every job",
    "Built for the founder doing every job",
    "platform of harnesses for the technical founder",
    "platform of harnesses for the founder"
  ]

  # /products/code-my-spec now 301s to /developers (the 2026-07 install-page
  # restructure); lint the surfaces that actually render.
  @live_marketing_surfaces ["/users/register", "/users/log-in"]
  @dead_marketing_surfaces ["/", "/developers", "/install"]

  describe "live marketing surfaces" do
    for path <- @live_marketing_surfaces do
      test "no retired marketing phrases on #{path}", %{conn: conn} do
        {:ok, _lv, html} = live(conn, unquote(path))
        assert_no_retired_phrases(html, unquote(path))
      end
    end
  end

  describe "dead-view marketing surfaces" do
    for path <- @dead_marketing_surfaces do
      test "no retired marketing phrases on #{path}", %{conn: conn} do
        html = conn |> get(unquote(path)) |> html_response(200)
        assert_no_retired_phrases(html, unquote(path))
      end
    end
  end

  describe "shared marketing components" do
    # The install_signature component ships on every published blog post
    # (per .code_my_spec/issues/blog-post-install-signature.md). Hitting
    # a real /blog/:slug here requires a published fixture, so the
    # regression contract observes the component output directly — the
    # same string that ends up in the blog post HTML.
    test "no retired marketing phrases in the install_signature component" do
      html = render_component(&Layouts.install_signature/1, %{})
      assert_no_retired_phrases(html, "Layouts.install_signature/1")
    end
  end

  defp assert_no_retired_phrases(html, path) do
    for phrase <- @retired_phrases do
      refute html =~ phrase, """
      Retired marketing phrase found on #{path}: #{inspect(phrase)}

      Source of truth: marketing/06_messaging.md "Phrases to retire,
      permanently" (codemyspec_marketing repo). Replace with on-strategy
      phrasing from the engineer-founder lens (Lens A) or the Phoenix lens
      (Lens B) — see marketing/05_positioning.md "Phrases to use".
      """
    end
  end
end
