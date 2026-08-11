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

  use ExUnit.Case, async: true

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
    assert {:ok, %{status: status}} =
             Req.get("http://127.0.0.1:#{port}/anything", retry: false, receive_timeout: 2_000)

    assert is_integer(status)
  end

  test "an explicit port is still honoured" do
    # A test that needs a known port keeps its escape hatch; the default is
    # what changed.
    {:ok, probe} = :gen_tcp.listen(0, [])
    {:ok, chosen} = :inet.port(probe)
    :gen_tcp.close(probe)

    assert FakeUpstream.start!(port: chosen) == chosen
  end
end
