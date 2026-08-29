defmodule CodeMySpec.ResearchFetchTest do
  @moduledoc """
  Reading one URL: which strategy handles it, what comes back as Markdown, and
  what a page that cannot be read says instead.

  The two per-site strategies exist because the generic reading of those URLs
  is close to worthless — a GitHub blob page is an application wrapped around a
  file, a Reddit thread is a scroller that has not loaded — so both are asserted
  on the thing the strategy changes rather than on the fact that it ran.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Research
  alias CodeMySpec.Research.Fetch

  describe "an ordinary page" do
    test "comes back as Markdown, without the furniture" do
      html = """
      <html>
        <head><title>Upserts in Ecto</title><style>body{color:red}</style></head>
        <body>
          <nav><a href="/">Home</a><a href="/about">About</a></nav>
          <main>
            <h1>Upserts</h1>
            <p>Use <code>on_conflict</code> to upsert.</p>
            <ul><li>First</li><li>Second</li></ul>
            <a href="https://hexdocs.pm/ecto">the docs</a>
          </main>
          <footer>Copyright 2026</footer>
          <script>analytics()</script>
        </body>
      </html>
      """

      stub_html(html)

      assert {:ok, page} = Research.fetch("https://example.com/upserts")

      assert page.title == "Upserts in Ecto"
      assert page.content =~ "# Upserts"
      assert page.content =~ "`on_conflict`"
      assert page.content =~ "- First"
      assert page.content =~ "[the docs](https://hexdocs.pm/ecto)"

      # The whole reason for stripping rather than converting faithfully: this
      # is what an agent would otherwise be charged to read.
      refute page.content =~ "About"
      refute page.content =~ "Copyright"
      refute page.content =~ "analytics()"
      refute page.content =~ "color:red"
    end

    test "drops controls even when they are nested inside the main region" do
      # Shaped after a real HexDocs page, where the search box and the settings
      # modal live inside `<main>`. Selecting the main region does not exclude
      # them, so the first thing an agent read was "Search documentation of
      # Elixir / Elixir + libraries / Settings".
      stub_html("""
      <html><body>
        <main>
          <div class="top-search">
            <form><label>Search documentation of Elixir</label><input placeholder="Elixir + libraries"></form>
            <button>Settings</button>
          </div>
          <div id="top-content">
            <h1>GenServer</h1>
            <p>A behaviour module.</p>
            <span aria-hidden="true">icon</span>
          </div>
        </main>
      </body></html>
      """)

      assert {:ok, page} = Research.fetch("https://hexdocs.pm/elixir/GenServer.html")

      assert page.content =~ "# GenServer"
      assert page.content =~ "A behaviour module."

      refute page.content =~ "Search documentation"
      refute page.content =~ "Settings"
      refute page.content =~ "icon"
    end

    test "numbers an ordered list, because the order is the content" do
      stub_html(
        "<html><body><main><ol><li>Add the dep</li><li>Restart</li></ol></main></body></html>"
      )

      assert {:ok, page} = Research.fetch("https://example.com/steps")
      assert page.content =~ "1. Add the dep"
      assert page.content =~ "2. Restart"
    end

    test "keeps a code block whole" do
      stub_html("""
      <html><body><main><pre><code>def hello do
        :world
      end</code></pre></main></body></html>
      """)

      assert {:ok, page} = Research.fetch("https://example.com/code")
      assert page.content =~ "```"
      assert page.content =~ "def hello do"
      assert page.content =~ ":world"
    end
  end

  describe "other content types" do
    test "JSON is pretty-printed" do
      Req.Test.stub(Research, fn conn -> Req.Test.json(conn, %{"a" => %{"b" => 1}}) end)

      assert {:ok, page} = Research.fetch("https://api.example.com/thing")
      assert page.content =~ "\"a\": {"
      assert page.content =~ "\"b\": 1"
    end

    test "plain text passes through" do
      Req.Test.stub(Research, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, "just words")
      end)

      assert {:ok, page} = Research.fetch("https://example.com/robots.txt")
      assert page.content == "just words"
    end

    test "a binary is described rather than dumped" do
      Req.Test.stub(Research, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, :binary.copy(<<0xFF, 0xD8>>, 5000))
      end)

      assert {:ok, page} = Research.fetch("https://example.com/logo.png")

      assert page.content =~ "image/png"
      assert page.content =~ "KB"
      refute String.contains?(page.content, <<0xFF, 0xD8>>)
    end
  end

  describe "GitHub" do
    test "a blob URL is read as the raw file" do
      Req.Test.stub(Research, fn conn ->
        # The rewrite is the entire strategy: same bytes, different host, and
        # the line anchor dropped because a raw file has no anchors.
        assert conn.host == "raw.githubusercontent.com"
        assert conn.request_path == "/elixir-lang/elixir/main/lib/elixir/lib/map.ex"

        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, "defmodule Map do\nend")
      end)

      assert {:ok, page} =
               Research.fetch(
                 "https://github.com/elixir-lang/elixir/blob/main/lib/elixir/lib/map.ex#L42"
               )

      assert page.content == "defmodule Map do\nend"
    end

    test "a repository page is not a file, so it is read normally" do
      assert Fetch.strategy(URI.parse("https://github.com/elixir-lang/elixir")) == Fetch.Default
    end
  end

  describe "Reddit" do
    test "is refused without a request, rather than answered with a login wall" do
      # No stub installed on purpose: a request here would raise, so this also
      # asserts that nothing is fetched.
      assert {:error, :reddit_requires_oauth} =
               Research.fetch("https://www.reddit.com/r/elixir/comments/abc/why_genservers/")

      assert {:error, :reddit_requires_oauth} = Research.fetch("https://old.reddit.com/r/elixir/")
    end

    test "which is the point — the wall is a page, and converts like one" do
      # This is what falling through to `Default` would produce: a clean,
      # confident, entirely useless answer to a question about a thread. It is
      # the reason the strategy refuses instead of being deleted.
      stub_html("""
      <html><head><title>Welcome to Reddit</title></head><body><main>
        <h1>Log in or sign up</h1>
        <p>Log in or sign up to personalize your feed, join conversations, vote, and explore communities.</p>
      </main></body></html>
      """)

      assert {:ok, page} = Research.fetch("https://example.com/looks-like-reddit")
      assert page.title == "Welcome to Reddit"
      assert page.content =~ "Log in or sign up"
    end
  end

  describe "refusals" do
    test "a scheme that would read the server's disk is named and refused" do
      assert {:error, {:unsupported_scheme, "file"}} = Research.fetch("file:///etc/passwd")
      assert {:error, {:unsupported_scheme, "data"}} = Research.fetch("data:text/plain,hi")
    end

    test "a non-2xx is the status and what the server said" do
      Req.Test.stub(Research, fn conn -> Plug.Conn.send_resp(conn, 404, "Not Found") end)

      assert {:error, {:status, 404, "Not Found"}} = Research.fetch("https://example.com/gone")
    end
  end

  describe "truncation" do
    test "is applied and reported, never silent" do
      stub_html("<html><body><main><p>#{String.duplicate("word ", 500)}</p></main></body></html>")

      assert {:ok, page} = Research.fetch("https://example.com/long", max_output: 100)

      assert page.truncated
      assert byte_size(page.content) <= 100
    end

    test "cuts on a character boundary, so the result still encodes as JSON" do
      # The cut lands mid-emoji if it is taken as bytes, and invalid UTF-8 does
      # not survive the MCP response encoder — the agent would get a transport
      # error rather than a short page.
      stub_html("<html><body><main><p>#{String.duplicate("🙂", 50)}</p></main></body></html>")

      assert {:ok, page} = Research.fetch("https://example.com/emoji", max_output: 30)

      assert String.valid?(page.content)
      assert {:ok, _json} = Jason.encode(page.content)
    end
  end

  defp stub_html(html) do
    Req.Test.stub(Research, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(200, html)
    end)
  end
end
