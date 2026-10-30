defmodule CodeMySpecWeb.Plugs.SafeCodeReloader do
  @moduledoc """
  `Phoenix.CodeReloader`, but a crash while checking for a recompile never
  reaches the request.

  d8b4226e: `Phoenix.CodeReloader.Server` is part of the `:phoenix` OTP
  application's own supervision tree, started once when `:phoenix` starts
  rather than per endpoint, and self-heals on a crash the same way any other
  supervised child does. A request that lands in the narrow window before
  that restart completes hit `GenServer.call(Phoenix.CodeReloader.Server,
  {:reload!, ...}, :infinity)` against no such process, which raised
  straight out of the plug -- and since `debug_errors: true` (dev, demo)
  wraps this whole endpoint in `Plug.Debugger`, the crash surfaced as a 500
  whose debug page renders `conn.req_headers` verbatim, including
  `authorization` and any session cookie the request carried. Reported
  against `/mcp/harness`, which every agent session's own calls go through.

  Checking for a recompile is exactly as skippable as the code actually
  being stale for one request: the next request tries again. Letting that
  failure crash the whole request, and from there reach a page that dumps
  the request's own credentials, is not an acceptable price for a check this
  disposable. Catching here, at the one plug the failure actually came from,
  needed no change to how any header is read or carried anywhere else in the
  pipeline.
  """

  @behaviour Plug

  require Logger

  @impl true
  def init(opts), do: Phoenix.CodeReloader.init(opts)

  @impl true
  def call(conn, opts) do
    reloader = Keyword.fetch!(opts, :reloader)

    case reloader.(conn.private.phoenix_endpoint, opts) do
      :ok ->
        conn

      {:error, output} = error ->
        Logger.error("[CodeMySpecWeb] Phoenix.CodeReloader compile failed:\n#{output}")

        if String.starts_with?(conn.request_path, "/mcp/") do
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.put_resp_header("retry-after", "1")
          |> Plug.Conn.send_resp(503, "Code reload in progress; retry shortly.")
          |> Plug.Conn.halt()
        else
          Phoenix.CodeReloader.call(conn, Keyword.put(opts, :reloader, fn _, _ -> error end))
        end
    end
  catch
    kind, reason ->
      Logger.warning(
        "[CodeMySpecWeb] Phoenix.CodeReloader failed (#{kind}: #{inspect(reason)}); " <>
          "serving this request without a reload check."
      )

      conn
  end
end
