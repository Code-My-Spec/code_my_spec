defmodule CodeMySpecWeb.Plugs.HoldDuringLanding do
  @moduledoc """
  Holds a request while a promotion is landing, so it is served the new code
  after its migrations rather than a PendingMigrationError 503 before them
  (issue 725a1d32).

  A landing merges into the checkout this app runs from, then migrates. Between
  the two the files are new and the database is not: the first request reloads
  the new code, `Phoenix.Ecto.CheckRepoStatus` sees pending migrations, and
  everything that arrives for about five seconds is a 503 — returned to agents
  as tool results too.

  `Steps.merge` writes `landing_hold` (a unix time) in the checkout's git directory
  before it merges. The `reload` recipe removes it after its loopback reload and
  health probes succeed; `serve` removes it after migration. Other requests wait
  up to 30 seconds, then receive a 503 with Retry-After while the marker remains
  fresh. A marker older than two minutes is ignored so an abandoned landing
  cannot hold requests indefinitely.

  Development only: the endpoint mounts this beside the code reloader.
  """

  @behaviour Plug

  @max_wait_ms 30_000
  @stale_seconds 120
  @poll_ms 100

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    path = Keyword.get(opts, :marker, marker_path())

    if probe?(conn) do
      conn
    else
      case hold(path, Keyword.get(opts, :max_wait_ms, @max_wait_ms), opts) do
        :ok ->
          conn

        :timeout ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "1")
          |> Plug.Conn.send_resp(503, "Promotion reload in progress; retry shortly.")
          |> Plug.Conn.halt()
      end
    end
  end

  defp marker_path, do: CodeMySpec.LandingHold.marker_path(File.cwd!())

  defp probe?(%Plug.Conn{remote_ip: {127, 0, 0, 1}, request_path: path}),
    do: path in ["/", "/health"]

  defp probe?(_conn), do: false

  defp hold(path, remaining, _opts) when remaining <= 0 do
    if holding?(path, System.os_time(:second)), do: :timeout, else: :ok
  end

  defp hold(path, remaining, opts) do
    if holding?(path, System.os_time(:second)) do
      Process.sleep(Keyword.get(opts, :poll_ms, @poll_ms))
      hold(path, remaining - Keyword.get(opts, :poll_ms, @poll_ms), opts)
    else
      :ok
    end
  end

  defp holding?(path, now) do
    with {:ok, text} <- File.read(path),
         {stamp, _} <- Integer.parse(String.trim(text)) do
      now - stamp <= @stale_seconds
    else
      _no_marker_or_unreadable -> false
    end
  end
end
