defmodule CodeMySpecWeb.Plugs.HoldDuringLandingTest do
  @moduledoc """
  Issue 725a1d32: a landing merges before it migrates, and the requests of that
  gap were PendingMigrationError 503s. The plug holds them until the migrations
  are in, and can never hold an app for good.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  alias CodeMySpecWeb.Plugs.HoldDuringLanding

  @moduletag :tmp_dir

  defp marker(dir), do: Path.join(dir, "landing_hold")
  defp request(opts), do: HoldDuringLanding.call(conn(:get, "/"), HoldDuringLanding.init(opts))

  # The request in its own process, so "went straight through" is a message that
  # arrives and not a stopwatch.
  defp requested(opts) do
    test = self()
    spawn_link(fn -> send(test, {:done, request(opts)}) end)
  end

  test "no marker: the request goes straight through", %{tmp_dir: dir} do
    requested(marker: marker(dir))

    assert_receive {:done, %Plug.Conn{halted: false}}, 1_000
  end

  test "a marker holds the request until it is removed", %{tmp_dir: dir} do
    path = marker(dir)
    File.write!(path, Integer.to_string(System.os_time(:second)))
    requested(marker: path, poll_ms: 5)

    refute_receive {:done, _}, 100

    File.rm!(path)
    assert_receive {:done, %Plug.Conn{halted: false}}, 2_000
  end

  test "a marker older than two minutes is ignored", %{tmp_dir: dir} do
    path = marker(dir)
    File.write!(path, Integer.to_string(System.os_time(:second) - 121))

    requested(marker: path, poll_ms: 5)

    assert_receive {:done, _}, 1_000
  end

  test "a marker that never goes is waited on for a bounded time, then let through", %{
    tmp_dir: dir
  } do
    path = marker(dir)
    File.write!(path, Integer.to_string(System.os_time(:second)))

    # 30s is the real ceiling; a short one is used so the test does not take it.
    {micros, conn} = :timer.tc(fn -> request(marker: path, poll_ms: 10, max_wait_ms: 100) end)

    assert conn.halted == false
    assert micros >= 100_000, "it must have waited"
    assert micros < 2_000_000
  end

  test "an unreadable marker does not hold anything", %{tmp_dir: dir} do
    path = marker(dir)
    File.write!(path, "not a time")

    requested(marker: path, poll_ms: 5)

    assert_receive {:done, _}, 1_000
  end
end
