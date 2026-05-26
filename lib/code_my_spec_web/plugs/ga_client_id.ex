defmodule CodeMySpecWeb.Plugs.GaClientId do
  @moduledoc """
  Reads the visitor's GA4 cookies and stores the parsed stitch identifiers
  in the session, so server-side Measurement Protocol conversions can attach
  to the same GA4 user/session as the browser's gtag pageviews.

  - `_ga` → client_id (session key `"ga_client_id"`). Format
    `GA1.<domain_depth>.<X>.<Y>`; the client_id is the `<X>.<Y>` tail.
  - `_ga_<container>` → session_id (session key `"ga_session_id"`). Format
    `GS1.<domain_depth>.<session_id>.<...>`; the session_id is field 3. The
    container suffix is the configured GA4 measurement_id with its `G-`
    prefix removed (e.g. measurement_id `G-ABC123` → cookie `_ga_ABC123`).

  Rule f9b2c751 (story 812): server MP conversions carry the visitor's gtag
  client_id AND session_id so they stitch to the same GA4 session as the
  browser pageviews — avoiding orphan sessions and double-counting.

  Both values are written to the session only when present and parseable, and
  are rewritten on each request so rotation (long sessions, new devices) is
  picked up. Must run after `Plug.Session`.
  """

  import Plug.Conn

  alias CodeMySpec.Analytics.GoogleAnalytics

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    conn
    |> maybe_put_session("ga_client_id", parse_ga_cookie(conn.req_cookies["_ga"]))
    |> maybe_put_session("ga_session_id", parse_ga_session_cookie(conn))
  end

  defp maybe_put_session(conn, _key, nil), do: conn
  defp maybe_put_session(conn, key, value), do: put_session(conn, key, value)

  # _ga: GA1.<domain_depth>.<X>.<Y> — client_id is the "<X>.<Y>" tail.
  defp parse_ga_cookie(nil), do: nil

  defp parse_ga_cookie(value) when is_binary(value) do
    case String.split(value, ".", parts: 3) do
      ["GA1", _domain_depth, client_id] when client_id != "" -> client_id
      _ -> nil
    end
  end

  # _ga_<container>: GS1.<domain_depth>.<session_id>.<...> — session_id is field 3.
  defp parse_ga_session_cookie(conn) do
    with name when is_binary(name) <- ga_session_cookie_name(),
         value when is_binary(value) <- conn.req_cookies[name],
         ["GS1", _domain_depth, session_id | _] <- String.split(value, "."),
         true <- session_id != "" do
      session_id
    else
      _ -> nil
    end
  end

  # Container suffix = configured measurement_id sans the "G-" prefix.
  defp ga_session_cookie_name do
    case Application.get_env(:code_my_spec, GoogleAnalytics, [])[:measurement_id] do
      "G-" <> container -> "_ga_" <> container
      _ -> nil
    end
  end
end
