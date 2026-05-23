defmodule CodeMySpecWeb.Plugs.PageView do
  @moduledoc """
  Dispatches `:page_view` via `CodeMySpec.Analytics.dispatch/3` on every
  GET request through the browser pipeline. Server-side replacement for
  the gtag.js `gtag('event', 'page_view', ...)` we used to fire from the
  client.

  Why server-side: gtag.js measurably hurts page-speed, and mobile in-app
  webviews routinely strip or break the JS-driven analytics path. A
  Phoenix plug guarantees the dispatch fires for every page rendered,
  regardless of webview JS limitations.

  ## Filtered requests

  Three classes of requests are NOT dispatched:

  - **Known-bot User-Agents** (matches `@bot_patterns` — case-insensitive
    on `bot`, `crawler`, `spider`, `scraper`, `headlesschrome`).
  - **Empty-signal requests** — both Referer AND User-Agent blank.
  - **Non-GET requests** — POSTs / PUTs / etc. don't constitute a pageload.

  ## Dispatched payload

      %{
        path: conn.request_path,           # "/products/code-my-spec"
        referrer: <Referer header value>,  # absolute URL or ""
        user_agent: <User-Agent value>,
        source: <derived from referrer>    # e.g. "reddit.com" — omitted when nil
      }

  Empty/nil keys are dropped so the GA Measurement Protocol payload
  stays small.
  """

  alias CodeMySpec.Analytics

  @bot_patterns [
    ~r/bot/i,
    ~r/crawler/i,
    ~r/spider/i,
    ~r/scraper/i,
    ~r/headlesschrome/i
  ]

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    if dispatch?(conn) do
      payload = build_payload(conn)
      Analytics.dispatch(:page_view, payload, :server)
    end

    conn
  end

  def call(conn, _opts), do: conn

  defp dispatch?(conn) do
    ua = header(conn, "user-agent")
    ref = header(conn, "referer")

    cond do
      bot_ua?(ua) -> false
      ua == "" and ref == "" -> false
      true -> true
    end
  end

  defp build_payload(conn) do
    ref = header(conn, "referer")

    %{
      path: conn.request_path,
      referrer: ref,
      user_agent: header(conn, "user-agent"),
      source: extract_source(ref)
    }
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp header(conn, key) do
    case Plug.Conn.get_req_header(conn, key) do
      [val | _] -> val
      [] -> ""
    end
  end

  defp bot_ua?(""), do: false
  defp bot_ua?(ua) when is_binary(ua), do: Enum.any?(@bot_patterns, &Regex.match?(&1, ua))

  defp extract_source(""), do: nil

  defp extract_source(referrer) when is_binary(referrer) do
    case URI.parse(referrer) do
      %URI{host: host} when is_binary(host) and host != "" ->
        String.replace_prefix(host, "www.", "")

      _ ->
        nil
    end
  end
end
