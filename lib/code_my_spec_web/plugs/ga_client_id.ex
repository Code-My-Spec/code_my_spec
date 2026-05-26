defmodule CodeMySpecWeb.Plugs.GaClientId do
  @moduledoc """
  Reads the visitor's `_ga` cookie and stores the parsed client_id in
  the session so LiveViews can access it via `get_session(socket, "ga_client_id")`.

  Purpose: GA4 Measurement Protocol server-side conversion events
  (sign_up, registration_email_sent, first_cli_connect) must carry the
  same client_id as the browser's gtag session. The `_ga` cookie holds
  this value in the format `GA1.1.<X>.<Y>` — the client_id is `<X>.<Y>`.

  By writing it to the session on every request, server-side MP
  dispatchers can stitch conversions to the browser session without
  receiving the cookie directly. The value is only written if the
  cookie is present and parseable, and it's rewritten on each request
  so rotation (long sessions, new devices) is picked up automatically.

  This plug must run after `Plug.Session` and after
  `Plug.Conn.fetch_cookies/1` (implicitly called by session fetch).
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case fetch_ga_client_id(conn) do
      nil -> conn
      client_id -> put_session(conn, "ga_client_id", client_id)
    end
  end

  # Parses the _ga cookie and returns the <X>.<Y> client_id tail.
  # Cookie format: GA1.1.<client_id_part1>.<client_id_part2>
  # Returns nil if the cookie is absent or malformed.
  defp fetch_ga_client_id(conn) do
    conn = fetch_cookies(conn)

    case conn.req_cookies["_ga"] do
      nil -> nil
      value -> parse_ga_cookie(value)
    end
  end

  defp parse_ga_cookie(value) when is_binary(value) do
    case String.split(value, ".", parts: 3) do
      ["GA1", _domain_level, client_id] when client_id != "" -> client_id
      _ -> nil
    end
  end
end
