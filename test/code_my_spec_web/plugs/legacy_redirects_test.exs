defmodule CodeMySpecWeb.Plugs.LegacyRedirectsTest do
  use CodeMySpecTest.ConnCase, async: true

  alias CodeMySpecWeb.Plugs.LegacyRedirects

  describe "call/2 — /pages/{slug} → /blog/{slug}" do
    test "301 redirects a migrated blog slug", %{conn: conn} do
      conn = LegacyRedirects.call(%{conn | method: "GET", request_path: "/pages/cli-agents-compared-2026"}, [])

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/blog/cli-agents-compared-2026"]
      assert conn.halted
    end

    test "301 redirects newer Reddit-target slugs that used to fall through to homepage", %{conn: conn} do
      for slug <- ~w(cursor-3-agent-first bdd-attention-thesis bdd-attention-three-amigos) do
        result =
          LegacyRedirects.call(%{conn | method: "GET", request_path: "/pages/#{slug}"}, [])

        assert result.status == 301, "expected 301 for /pages/#{slug}"
        assert get_resp_header(result, "location") == ["/blog/#{slug}"]
        assert result.halted
      end
    end

    test "301 redirects /docs to /documentation", %{conn: conn} do
      conn = LegacyRedirects.call(%{conn | method: "GET", request_path: "/docs"}, [])

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/documentation"]
      assert conn.halted
    end

    test "preserves the query string on redirect", %{conn: conn} do
      conn =
        %{
          conn
          | method: "GET",
            request_path: "/pages/the-harness-layer",
            query_string: "utm_source=reddit&utm_medium=comment"
        }
        |> LegacyRedirects.call([])

      assert conn.status == 301
      assert get_resp_header(conn, "location") == [
               "/blog/the-harness-layer?utm_source=reddit&utm_medium=comment"
             ]
    end
  end

  describe "call/2 — custom-target redirects" do
    test "301 redirects /pages/methodology → /methodology", %{conn: conn} do
      conn = LegacyRedirects.call(%{conn | method: "GET", request_path: "/pages/methodology"}, [])

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/methodology"]
      assert conn.halted
    end
  end

  describe "call/2 — pass-through" do
    test "leaves unknown /pages/ paths untouched", %{conn: conn} do
      conn = LegacyRedirects.call(%{conn | method: "GET", request_path: "/pages/about"}, [])

      refute conn.halted
      assert conn.status == nil
    end

    test "leaves non-GET requests untouched", %{conn: conn} do
      conn =
        LegacyRedirects.call(
          %{conn | method: "POST", request_path: "/pages/cli-agents-compared-2026"},
          []
        )

      refute conn.halted
      assert conn.status == nil
    end

    test "leaves /blog/ and /products/ paths untouched", %{conn: conn} do
      for path <- ~w(/blog/cli-agents-compared-2026 /products/code-my-spec /) do
        result = LegacyRedirects.call(%{conn | method: "GET", request_path: path}, [])
        refute result.halted, "expected #{path} to pass through"
      end
    end
  end

  describe "redirect_paths/0" do
    test "returns the set of /pages/ paths the plug intercepts" do
      paths = LegacyRedirects.redirect_paths()

      assert MapSet.member?(paths, "/pages/cli-agents-compared-2026")
      assert MapSet.member?(paths, "/pages/cursor-3-agent-first")
      assert MapSet.member?(paths, "/pages/methodology")
      refute MapSet.member?(paths, "/pages/about")
      refute MapSet.member?(paths, "/blog/cli-agents-compared-2026")
    end
  end
end
