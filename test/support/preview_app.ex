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

  # Where a generated Phoenix app's LiveView socket lives. Echoes rather than
  # speaking the real protocol: what the proxy criteria ask is whether frames
  # cross intact in both directions, and LiveView's own protocol is its
  # business — a proxy that understood it would be a proxy that could get it
  # wrong.
  @impl true
  def call(%Plug.Conn{request_path: "/live/websocket"} = conn, _body) do
    conn
    |> WebSockAdapter.upgrade(CodeMySpecTest.PreviewApp.Echo, :ok, timeout: 10_000)
    |> halt()
  end

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
    # What the app was actually asked, as opposed to what the proxy believed it
    # asked. This stand-in answers every method 200, where a real Phoenix app
    # 404s a POST to `/` — so without saying so, a GET relayed as a POST looks
    # identical to a working proxy.
    |> put_resp_header("x-preview-app-method", conn.method)
    |> send_resp(200, body)
  end
end

defmodule CodeMySpecTest.PreviewApp.Echo do
  @moduledoc """
  The app's end of the preview socket.

  Echoes each frame back with a marker, so a spec can tell a frame that made
  the round trip from one the proxy invented. Also pushes unprompted, which is
  the direction that matters: LiveView updates arrive because the server
  decided to send them, not in reply to anything.
  """

  @behaviour WebSock

  @impl true
  def init(_), do: {:push, {:text, "hello from the app"}, %{}}

  @impl true
  def handle_in({text, opcode: :text}, state), do: {:push, {:text, "app saw: " <> text}, state}

  def handle_in({data, opcode: :binary}, state), do: {:push, {:binary, data}, state}

  @impl true
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
