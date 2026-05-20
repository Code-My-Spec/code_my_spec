defmodule CodeMySpecWeb.Components.InstallSignatureTest do
  @moduledoc """
  Contract spec for the end-of-blog-post install signature component
  (`CodeMySpecWeb.Layouts.install_signature/1`).

  The signature ships on every published blog post per
  `.code_my_spec/issues/blog-post-install-signature.md`. The audience is
  senior Phoenix engineers / agency tech leads — they read aggressive
  end-of-post CTAs as marketing smell. The contract below enforces the
  "author signature, not a sales card" shape: monospace, no buttons, no
  primary-color CTA backgrounds, no urgency framing, UTM-tagged signup
  URL preserved exactly.
  """

  use CodeMySpecTest.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias CodeMySpecWeb.Layouts

  describe "install_signature/1" do
    setup do
      html = render_component(&Layouts.install_signature/1, %{})
      %{html: html}
    end

    test "ships the exact author-voice copy from the issue spec", %{html: html} do
      # "CodeMySpec" is now a link to the case study so the literal
      # sentence is broken by an <a> tag — assert each piece separately.
      assert html =~ "I built this with"
      assert html =~ ">CodeMySpec</a>"
      assert html =~ "— the harness I work in."
      assert html =~ "Sign up (free, no card) then install:"
      assert html =~ "— John"
    end

    test "links the 'CodeMySpec' word to the MMS case study with UTM tags", %{html: html} do
      # Serves the skeptical Phoenix engineer ("does anyone actually
      # build with this?") — one word becomes a link, zero visual
      # weight added, and the MMS case study is the CMS-recursion
      # proof they'd want to see.
      assert html =~
               ~s|href="/case-studies/market-my-spec?utm_source=blog&utm_medium=signature&utm_campaign=post-cta"|
    end

    test "displays the install commands as terminal text, not as links", %{html: html} do
      assert html =~ "/plugin marketplace add Code-My-Spec/plugins"
      assert html =~ "/plugin install codemyspec@codemyspec"
      # The commands appear in <p> tags inside the bordered terminal
      # block, never inside an <a href>.
      refute html =~ ~s|href="/plugin|
      refute html =~ ~s|href="#{"/plugin"}|
    end

    test "links signup with UTM tags preserved in href, clean URL in display", %{html: html} do
      # HEEx leaves `&` as-is in href attributes when the URL params
      # can't be parsed as character references (HTML5-valid). The href
      # carries the UTM payload so blog → register conversion tracks
      # separately from nav / homepage / Reddit-comment paths.
      assert html =~
               ~s|href="/users/register?utm_source=blog&utm_medium=signature&utm_campaign=post-cta"|

      # Visible link text is the clean URL — devs reading the post see
      # a readable URL, not a tracking string. Right-click → copy-link
      # still grabs the UTM'd href for any edge-case tracking.
      assert html =~ "https://codemyspec.com/users/register"
      refute html =~ ">https://codemyspec.com/users/register?utm_source"
    end

    test "renders as an author signature, not a marketing card", %{html: html} do
      # The block must NOT look like a CTA — no btn classes, no primary
      # background fills, no urgency framing. These are the explicit
      # "what NOT to ship" items from the issue.
      refute html =~ "btn-primary"
      refute html =~ "btn btn-"
      refute html =~ "bg-primary "
      refute html =~ "GET STARTED"
      refute html =~ "Sign up now"
      refute html =~ "!"
      refute html =~ "Limited time"
      refute html =~ "Don't miss"
      refute html =~ "Join thousands"
      refute html =~ "10x"
    end

    test "uses monospace styling and a horizontal-rule-style top border", %{html: html} do
      # font-mono applied to the whole block.
      assert html =~ "font-mono"
      # `border-t border-primary/20` is the brand's hairline divider —
      # matches how article.html.heex separates the Prev/Next nav from
      # the article body.
      assert html =~ "border-t border-primary/20"
    end
  end
end
