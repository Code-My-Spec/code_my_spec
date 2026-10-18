defmodule CodeMySpecWeb.ARefusedSocketUpgradeNamesWhyInItsResponseTest do
  @moduledoc """
  Issue 62377cc3: a refused websocket upgrade answered a bare 403 with an
  empty body on either side. `d96809d4` fixed half of this -- the server's
  own log now names the caller and the credential -- but the CALLER (a
  harness retrying on a backoff) never saw any of it: Phoenix's stock
  websocket transport (`Phoenix.Transports.WebSocket.handle_error/2`)
  discards whatever reason `connect/3` returns and always sends `""`, so a
  harness logging `{:error, {:upgrade_failure, ...}}` could only say the far
  side said no, with nothing to tell a dead credential (never going to
  succeed on retry) from a transient refusal apart.

  `endpoint.ex` now configures a custom `:error_handler` for `/socket`
  (`UserSocket.handle_connect_error/2`), reached because `connect/3`'s
  refusal clauses return `{:error, reason}` instead of a bare `:error` --
  stock Phoenix only applies the configurable error handler for the tagged
  form (`phoenix/lib/phoenix/transports/websocket.ex`: a bare `:error`
  always short-circuits to the fixed empty-body 403, not the error_handler).

  Driven as a real HTTP request against the real endpoint and router, not a
  direct call to `UserSocket.connect/3` -- the whole point under test is
  what actually reaches an HTTP caller.
  """
  use CodeMySpecTest.ConnCase, async: true

  test "a missing token is refused with a reason a caller can read", %{conn: conn} do
    conn = get(conn, "/socket/websocket")

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "missing_token"}
  end

  test "an unknown credential is refused with a reason a caller can read", %{conn: conn} do
    conn = get(conn, "/socket/websocket", %{"token" => "dk_does-not-exist"})

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "token_not_found"}
  end
end
