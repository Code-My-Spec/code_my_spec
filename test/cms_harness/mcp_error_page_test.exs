defmodule CmsHarness.McpErrorPageTest do
  @moduledoc """
  When the server answers a tool call with a debug page, say what broke.

  The transport already detects the page and adds a "common causes" hint —
  `6ecb257a`'s first suggestion, half-taken. What it surfaces is the wrong
  300 characters. Phoenix's debug page opens with an inline `<style>` block, so
  stripping tags leaves the stylesheet's *contents*, and the extract that
  reaches the agent is:

      CompileError /*! normalize.css v4.2.0 | MIT License |
      github.com/necolas/normalize.css */html{font-family:sans-serif; ...

  Received verbatim during this session. The one sentence that matters —
  "could not compile application: code_my_spec. You must restart your server
  after changing configuration files" — sits further down and never arrives.
  An agent that truncates long tool results gets CSS and no cause, which is
  the complaint the issue opens with.

  So `<style>` and `<script>` bodies are dropped before tags are stripped, and
  the exception marker wins when the page has one. Both matter: the marker is
  the useful line, and dropping the noise is what stops it being crowded out
  in pages that render the exception differently.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Web.UpstreamError

  # The shape Phoenix actually sends: a title, an inline stylesheet, then the
  # exception. Trimmed, but the ordering is what matters and it is faithful.
  defp debug_page(exception) do
    """
    <!DOCTYPE html>
    <html><head><title>CompileError at POST /mcp</title>
    <style>/*! normalize.css v4.2.0 | MIT License | github.com/necolas/normalize.css */
    html{font-family:sans-serif;line-height:1.15;-ms-text-size-adjust:100%}body{margin:0}
    article,aside,details,figcaption,figure,footer,header,main,menu,nav,section{display:block}</style>
    </head><body><div class="exception-info"><pre>#{exception}</pre></div></body></html>
    """
  end

  @compile_error """
  ** (RuntimeError) could not compile application: code_my_spec.
  You must restart your server after changing configuration files or your dependencies.
  In particular, the following files changed and must be recomputed on a server restart:
    * config/config.exs
  """

  describe "a Phoenix debug page" do
    test "surfaces the exception rather than the stylesheet" do
      summary = UpstreamError.summary(debug_page(@compile_error), 500, "text/html")

      assert summary =~ "could not compile application: code_my_spec",
             "this is the only sentence in 30KB that tells anyone what to do"

      refute summary =~ "normalize.css",
             "the stylesheet is what currently wins the first 300 characters"

      refute summary =~ "font-family"
    end

    test "keeps the actionable hint" do
      summary = UpstreamError.summary(debug_page(@compile_error), 500, "text/html")

      assert summary =~ "cannot hot-reload",
             "no agent can fix this; the hint is what sends it to a human restart"
    end

    test "still says something when the page carries no exception marker" do
      page = """
      <!DOCTYPE html><html><head><style>body{margin:0}</style></head>
      <body><h1>Bad Gateway</h1></body></html>
      """

      summary = UpstreamError.summary(page, 502, "text/html")

      assert summary =~ "Bad Gateway"
      refute summary =~ "margin"
    end
  end

  describe "a page rendered as markdown rather than HTML" do
    test "is still recognised by its exception marker" do
      # The MCP client sends `application/json, text/event-stream`, and Phoenix
      # renders its debug page in whatever the request accepts — so a
      # `PendingMigrationError` arrived as markdown and sailed past an
      # HTML-only check once already.
      body = "# PendingMigrationError\n\n** (Ecto.MigrationError) pending migrations\n"

      summary = UpstreamError.summary(body, 500, "text/markdown")

      assert summary =~ "pending migrations"
    end
  end

  describe "a normal response" do
    test "is not treated as an error page" do
      assert UpstreamError.summary(~s({"jsonrpc":"2.0"}), 200, "application/json") ==
               nil
    end
  end

  # The same page reaches `harness.log` by a second route: the permission path
  # forwards the server's body into an error tuple whose caller logs it, and a
  # log message is not truncated the way metadata is. One implementation, so the
  # 300 characters chosen are the same ones in both places (6ecb257a).
  describe "reuse off the MCP path" do
    test "a page with no content-type is still recognised" do
      summary = UpstreamError.summary(debug_page(@compile_error), 500, nil)

      assert summary =~ "** (RuntimeError)"
      assert summary =~ "restart"
    end

    test "an ordinary error body is left for the caller to handle" do
      refute UpstreamError.summary(~s({"error":"invalid_token"}), 401, "application/json")
    end
  end
end
