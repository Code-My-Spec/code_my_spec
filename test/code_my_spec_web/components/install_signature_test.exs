defmodule CodeMySpecWeb.Components.InstallSignatureTest do
  @moduledoc """
  Contract spec for the end-of-blog-post install signature component
  (`CodeMySpecWeb.Layouts.install_signature/1`).

  The signature ships on every published blog post per
  `.code_my_spec/issues/blog-post-install-signature.md`. The 2026-07
  install-page restructure evolved it from a bare monospace signature into a
  quiet card: author-voice copy, ONE register CTA, install commands in a
  terminal block, signed off by John. The contract below enforces that
  shape — a single clearly-labeled CTA with UTM-tagged href, commands as
  terminal text (never links), and still zero urgency framing.
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

    test "links signup with UTM tags preserved in href on the register CTA", %{html: html} do
      # HEEx leaves `&` as-is in href attributes when the URL params
      # can't be parsed as character references (HTML5-valid). The href
      # carries the UTM payload so blog → register conversion tracks
      # separately from nav / homepage / Reddit-comment paths.
      assert html =~
               ~s|href="/users/register?utm_source=blog&utm_medium=signature&utm_campaign=post-cta"|

      # The CTA is labeled for analytics and reads as an invitation,
      # not urgency.
      assert html =~ ~s|data-event-label="cta-signature-register"|
      assert html =~ "Create your free account"
    end

    test "renders as a quiet card with exactly one CTA and no urgency framing", %{html: html} do
      # One register button, nothing shouty — a single btn-primary and
      # none of the "what NOT to ship" phrases from the issue.
      assert length(String.split(html, "btn-primary")) == 2

      refute html =~ "GET STARTED"
      refute html =~ "Sign up now"
      refute html =~ "!"
      refute html =~ "Limited time"
      refute html =~ "Don't miss"
      refute html =~ "Join thousands"
      refute html =~ "10x"
    end

    test "renders install commands in a terminal block inside the card", %{html: html} do
      # The commands live in a mockup-code terminal block — readable,
      # copyable, visibly "type this in Claude Code".
      assert html =~ "mockup-code"
      # Card container, not a floating paragraph.
      assert html =~ ~s|class="not-prose mt-12 card|
    end
  end
end
