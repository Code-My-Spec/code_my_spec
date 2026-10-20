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

  `Steps.merge` writes `landing_hold` (a unix time) in the checkout's git directory (so it can never
  dirty the tree; see `CodeMySpec.LandingHold`) before it merges; the `reload` and `serve` recipes remove it once `mix ecto.migrate` has
  run. Requests wait for it to go. The wait is bounded two ways, so a landing that
  dies halfway can never hold the app: a request waits at most 30 seconds, and a
  marker older than two minutes is ignored.

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
    hold(
      Keyword.get(opts, :marker, marker_path()),
      Keyword.get(opts, :max_wait_ms, @max_wait_ms),
      opts
    )

    conn
  end

  defp marker_path, do: CodeMySpec.LandingHold.marker_path(File.cwd!())

  defp hold(_path, remaining, _opts) when remaining <= 0, do: :ok

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
