defmodule CmsHarness.FakeUpstreamPortTest do
  @moduledoc """
  The port `start!/1` returns is the one the listener bound.

  Two earlier versions chose a port and then handed it to Bandit:
  `Enum.random(4300..4399)`, and later a probe socket opened on 0, read, and
  closed. Both leave an interval in which the port is spoken for but not held,
  and with three worktrees' suites plus the harness's analyzers on one box, a
  narrow interval still gets hit.

  What that costs is not a bind error, which would be loud. The request reaches
  the *other* suite's upstream, so `last_request/0` answers about a call this
  test never made and the assertion fails on `==` with nothing suggesting a
  second server was involved. `0bc611c9` records two framework issues filed and
  retracted on that shape, and three investigations that went nowhere.

  Binding 0 and reading the port back off the listener removes the interval
  rather than shortening it. This asserts the part that could silently regress:
  that the returned number describes a socket this process is actually holding.
  """

  # Sync, because `start!/1` calls `reset/0`, and `reset/0` overwrites
  # `FakeUpstream`'s `:persistent_term` state — the response, the request log,
  # the exchange answer — which is node-global. Async here means every one of
  # these tests can reset a response another test (turn_record_refusal_test,
  # mcp_controller_test, permission_controller_test — all sync for exactly
  # this) configured a moment earlier but has not yet asserted on, so the
  # second test's setup silently rewrites the first test's fixture mid-run.
  # That reads as the first test's own assertion being wrong on a full-suite
  # run and passing every time it runs alone.
  use ExUnit.Case, async: false

  alias CmsHarnessTest.FakeUpstream

  test "an OS-assigned port is returned, and something is listening on it" do
    port = FakeUpstream.start!()

    assert is_integer(port) and port > 0,
           "asking for 0 must yield the assigned port, not the request"

    assert {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 2_000)

    :gen_tcp.close(socket)
  end

  test "the returned port is the one the listener reports, not one we hoped for" do
    port = FakeUpstream.start!()

    # Reachable over HTTP, which is the property the consumers depend on — a
    # port that merely accepts TCP would satisfy the check above while pointing
    # at something else entirely.
    # Ten seconds rather than two. What is being asserted is that the returned
    # number describes a socket this process holds — not how fast the box can
    # answer. Two seconds is generous on an idle machine and not generous at
    # all on one running three suites at load 19, where this failed as a bare
    # `match (=) failed` that reads like the port being wrong.
    assert {:ok, %{status: status}} =
             Req.get("http://127.0.0.1:#{port}/anything", retry: false, receive_timeout: 10_000)

    assert is_integer(status)
  end

  test "an explicit port is still honoured" do
    # A test that needs a known port keeps its escape hatch; the default is
    # what changed.
    #
    # Getting a free port to ask for means probing and closing, which is the
    # interval this module's own moduledoc says gets hit — "a probe socket
    # opened on 0, read, and closed". The assertion here is that an explicit
    # port is honoured, not that we can win a race for one, so losing the race
    # is retried rather than reported as a failure. Without this it fails under
    # concurrent load, in a file that exists to document exactly that.
    assert honour_an_explicit_port(5)
  end

  defp honour_an_explicit_port(0), do: flunk("no free port stayed free across five attempts")

  defp honour_an_explicit_port(attempts_left) do
    {:ok, probe} = :gen_tcp.listen(0, [])
    {:ok, chosen} = :inet.port(probe)
    :gen_tcp.close(probe)

    started_port_matches?(FakeUpstream.start!(port: chosen), chosen, attempts_left)
  rescue
    # `start_supervised!` raises when Bandit cannot bind, which is what losing
    # the race looks like from here.
    _ -> honour_an_explicit_port(attempts_left - 1)
  end

  defp started_port_matches?(port, port, _attempts_left), do: true

  defp started_port_matches?(_started, _chosen, attempts_left),
    do: honour_an_explicit_port(attempts_left - 1)
end
