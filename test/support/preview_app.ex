defmodule CodeMySpecTest.PreviewApp do
  @moduledoc """
  A real Phoenix-shaped app for the preview proxy to proxy to.

  Small on purpose, but genuinely served over a socket. The proxy criteria ask
  what survives the round trip, and a stubbed `Req` client cannot answer that:
  hop-by-hop headers, a `content-length` describing a body we did not send, and
  a `Set-Cookie` that has to reach the browser are all things that only go
  wrong once a real client and a real server are on the two ends.

  It answers three ways, matching what the criteria need to see:

    * `/` renders the app, and sets a session cookie the way Phoenix would
    * `/whoami` reports the cookie it was given back, so a spec can tell
      whether the browser's cookie reached the app
    * `/frame-guard` answers with `x-frame-options: DENY`, which is what a
      generated Phoenix app sends and what the proxy has to strip
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(body), do: body

  @impl true
  def call(%Plug.Conn{request_path: "/whoami"} = conn, _body) do
    conn = fetch_cookies(conn)
    who = Map.get(conn.req_cookies, "_preview_app_session", "nobody")

    send_resp(conn, 200, "session=#{who} host=#{conn.host}")
  end

  def call(%Plug.Conn{request_path: "/frame-guard"} = conn, _body) do
    conn
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_content_type("text/html")
    |> send_resp(200, "<p>guarded</p>")
  end

  def call(conn, body) do
    conn
    |> put_resp_cookie("_preview_app_session", "sam", http_only: true, same_site: "Lax")
    |> put_resp_content_type("text/html")
    |> send_resp(200, body)
  end
end
