defmodule CodeMySpec.Provisioning.FleetDnsTest do
  @moduledoc """
  Publish a record and serve it, for real, in about a second.

  This is the round-trip a registrar makes untestable: propagation is minutes,
  so the suite kept `test/cassettes/dns_resolutions.json` — a flat table of
  recorded answers, defaulting to `false`.

  A table cannot be wrong in the direction that matters. It can only be
  *absent*, and then every record reads as unresolved, which is
  indistinguishable from a publish that failed. That is exactly what happened
  when the file went missing from the working tree: criteria asserting that a
  published record resolves failed for reasons unrelated to publishing.

  ## Asked from inside the fleet, deliberately

  These queries run in a fleet container, over the fleet network, as ordinary
  UDP.

  The host cannot do that on macOS. Colima publishes container ports through an
  SSH mux, which carries TCP and not UDP — so a UDP query to `127.0.0.1:5354`
  times out — and the TCP path degrades under repeated connects. Measured: with
  the record in the file, the serial fresh, and CoreDNS logging a clean reload,
  host-side queries still failed about half of all runs. Polling harder made it
  worse, which is the tell — a race improves with patience and a saturated
  forward does not.

  So the transport is the limitation, not the design. `Dns` queries this server
  happily from anything running inside the fleet, and `:dns_nameserver` is the
  seam that points it there. For host-side use, running CoreDNS on the host
  rather than in a container removes the forward entirely and nothing else
  changes.

  Excluded by default (`:fleet`):

      docker/fleet/fleet.sh up
      mix test --only fleet
  """
  use ExUnit.Case, async: true

  @moduletag :fleet
  @moduletag timeout: 120_000

  @zone Path.expand("../../../docker/fleet/dns/zones/astralbi.test.zone", __DIR__)

  setup do
    original = File.read!(@zone)

    # Restored with a *higher* serial, never the original one. CoreDNS keeps the
    # zone it has if the file offers an older serial, so putting the original
    # number back leaves the server holding this test's records and ignoring the
    # next test's — which reads as a publish that did not take.
    on_exit(fn -> write_zone(with_serial(original)) end)

    :ok
  end

  describe "serving a zone the suite writes" do
    test "a record published now is served now" do
      name = "c#{System.unique_integer([:positive])}"

      publish(~s(#{name}   IN  TXT "published-by-the-suite"))

      assert query(name, "txt") =~ "published-by-the-suite",
             "a record written a moment ago should be served — publishing and reading " <>
               "it back is one round-trip here, which is the whole reason for serving " <>
               "this zone locally rather than against a registrar"
    end

    test "a name nobody published is not served" do
      # The half a lookup table gets wrong by construction. An absent table
      # answers `false` for everything, so an assertion like this passes there
      # whether or not the resolver works at all — it cannot tell "not
      # published" from "not asked". A real server says NXDOMAIN.
      refute query("never-published-#{System.unique_integer([:positive])}", "txt") =~ "text ="
    end

    test "MX and TXT are both served, not just addresses" do
      # Mail setup asserts on MX and TXT, which is why a hosts-style stand-in
      # would not do: it serves addresses only, and every mail criterion would
      # read as an unpublished record.
      name = "mail#{System.unique_integer([:positive])}"

      publish("""
      #{name}   IN  MX  10 inbound.astralbi.test.
      #{name}   IN  TXT "v=spf1 include:example.test ~all"
      """)

      assert query(name, "mx") =~ "inbound.astralbi.test"
      assert query(name, "txt") =~ "v=spf1"
    end
  end

  # Writes the records with a sentinel, and waits for the sentinel to be served
  # before returning.
  #
  # Polling for the record under test is a race: until CoreDNS reloads, the name
  # genuinely does not exist, so "not yet" and "never" are the same empty
  # answer. A sentinel written in the same file version turns it into a fact —
  # when the sentinel is visible, that version of the zone is loaded.
  defp publish(records), do: publish(records, 8)

  defp publish(_records, 0) do
    flunk("the zone never came to serve a freshly written record after repeated writes")
  end

  defp publish(records, tries) do
    serial = next_serial()
    sentinel = "loaded#{serial}"
    body = records <> "\n#{sentinel}   IN  TXT \"#{serial}\"\n"

    write_zone(with_serial(File.read!(@zone), serial) <> "\n" <> body)

    # Written again with a new serial if the first version does not come to be
    # served, rather than waited on for longer.
    #
    # CoreDNS logs a *successful* reload of the very serial just written and
    # then answers nothing for the record in that same write. The serial sits at
    # the top of the file and the record at the bottom, so what it read was a
    # file that was only partly visible — the write is atomic on the host
    # (`rename/2`), but the zone reaches CoreDNS through colima's bind mount,
    # and that boundary does not preserve it.
    #
    # Waiting does not fix a version already accepted: CoreDNS will not re-read
    # a file whose serial it has. Only a new serial makes it look again, and by
    # then the file is long since whole. Converges on the first retry in
    # practice.
    sentinel
    |> await_zone_loaded()
    |> rewrite_unless_served(records, tries)
  end

  defp rewrite_unless_served(:ok, _records, _tries), do: :ok
  defp rewrite_unless_served(:missing, records, tries), do: publish(records, tries - 1)

  defp await_zone_loaded(sentinel, attempts \\ 12) do
    sentinel
    |> query("txt")
    |> String.contains?("text =")
    |> retry_zone_load(sentinel, attempts)
  end

  defp retry_zone_load(false, sentinel, attempts) when attempts > 1 do
    Process.sleep(250)
    await_zone_loaded(sentinel, attempts - 1)
  end

  defp retry_zone_load(true, _sentinel, _attempts), do: :ok
  defp retry_zone_load(false, _sentinel, _attempts), do: :missing

  # busybox `nslookup` from a fleet container, so the query is UDP on the fleet
  # network with no port forward in the path. See the moduledoc for why the host
  # cannot ask this question reliably on macOS.
  defp query(name, type) do
    {out, _status} =
      System.cmd(
        "docker",
        [
          "exec",
          "cms-fleet-builder-1",
          "nslookup",
          "-type=#{type}",
          "#{name}.astralbi.test",
          "dns"
        ],
        stderr_to_stdout: true
      )

    out
  end

  # Written to a sibling and renamed, because `File.write!/2` is not atomic and
  # CoreDNS polls this file once a second. It caught partial writes and rejected
  # the whole zone — `bad TXT Txt: " "` — so the records never loaded on
  # whichever runs the poll happened to land mid-write. `rename/2` on the same
  # filesystem is atomic: the server sees the old file or the whole new one.
  defp write_zone(contents) do
    tmp = @zone <> ".writing"
    File.write!(tmp, contents)
    File.rename!(tmp, @zone)
  end

  # Seconds alone are too coarse: two tests less than a second apart drew the
  # same serial, CoreDNS declined the second write as not-newer, and those
  # records never loaded. The monotonic term only ever climbs within a run and
  # the clock carries it across runs, so a serial is never reissued.
  defp next_serial do
    System.os_time(:second) + System.unique_integer([:positive, :monotonic])
  end

  defp with_serial(zone, serial \\ nil) do
    value = serial || next_serial()

    Regex.replace(~r/(\n\s+)(\d+)(\s+; serial)/, zone, fn _, pre, _old, post ->
      pre <> to_string(value) <> post
    end)
  end
end
