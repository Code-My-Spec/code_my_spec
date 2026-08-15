defmodule CodeMySpec.Provisioning.DnsNegativeCacheTest do
  @moduledoc """
  Telling a cached "no" from a real one.

  Separate from `DnsTest`, which is `@moduletag :live` and asks real
  resolvers. These are stubbed on purpose: a cached negative cannot be
  conjured on demand, because it depends on some resolver having been asked
  during a window that has since closed.

  The bodies below were measured on 2026-08-14, when `c7995.astralbi.com` was
  published in Cloudflare, `dig @1.1.1.1` returned it, and the dns step
  reported that no public resolver returned it. Google was serving a negative
  cached from before the record was written, with 1489 of the zone's 1800
  seconds still to run.

  Names that cycle are where this bites: every spex label and every drill
  domain is created, destroyed and created again, and a resolver asked during
  the gap keeps saying no for half an hour after the record is back — longer
  than any step waits, so retrying cannot help and the only useful thing is to
  say which case it is.
  """
  # Not async: the settle tests switch `:provisioning_waits` back on, which is
  # application-wide. It is off in test so replayed cassettes do not reproduce
  # the waits they recorded, and the point of those tests is that the wait
  # happens at all.
  use ExUnit.Case, async: false

  alias CodeMySpec.Provisioning.Dns

  defp answered(data) do
    fn _url, _headers ->
      {:ok, %{status: 200, body: %{"Status" => 0, "Answer" => [%{"data" => data}]}}}
    end
  end

  # Straight from the authoritative server the SOA arrives at the zone's
  # minimum — the last field of its data. Anything lower is a resolver
  # counting down an entry of its own.
  defp negative(ttl) do
    fn _url, _headers ->
      {:ok,
       %{
         status: 200,
         body: %{
           "Status" => 3,
           "Authority" => [
             %{
               "type" => 6,
               "TTL" => ttl,
               "data" =>
                 "demi.ns.cloudflare.com. dns.cloudflare.com. 2412243971 10000 2400 604800 1800"
             }
           ]
         }
       }}
    end
  end

  describe "resolution_status/3" do
    test "an answer resolves" do
      assert Dns.resolution_status("c7995.astralbi.com", :a, resolver: answered("192.0.2.10")) ==
               :resolves
    end

    test "a negative below the zone minimum is cached, and says how much is left" do
      assert Dns.resolution_status("c7995.astralbi.com", :a, resolver: negative(1489)) ==
               {:absent, :cached, 1489}
    end

    test "a negative at the zone minimum is fresh — nothing has cached it" do
      assert Dns.resolution_status("c7995.astralbi.com", :a, resolver: negative(1800)) ==
               {:absent, :fresh}
    end

    # Both read as "no answer" to a caller that only asks yes or no, and
    # reporting the cached one as the fresh one is what sent me hunting a
    # publish bug for a record that was published.
    test "the two negatives are distinguishable" do
      refute Dns.resolution_status("x.astralbi.com", :a, resolver: negative(1489)) ==
               Dns.resolution_status("x.astralbi.com", :a, resolver: negative(1800))
    end

    # A body with no authority section at all — a resolver that answered
    # something unhelpful — must not be read as a cached negative, or a
    # genuinely missing record starts reporting as "just wait".
    test "an answer with nothing to say is fresh, not cached" do
      resolver = fn _url, _headers -> {:ok, %{status: 200, body: %{"Status" => 3}}} end

      assert Dns.resolution_status("x.astralbi.com", :a, resolver: resolver) == {:absent, :fresh}
    end
  end

  describe "resolves_publicly?/3" do
    test "still answers a plain boolean over the top of it" do
      assert Dns.resolves_publicly?("c7995.astralbi.com", :a, resolver: answered("192.0.2.10"))
      refute Dns.resolves_publicly?("c7995.astralbi.com", :a, resolver: negative(1489))
    end
  end

  describe "settle_ms" do
    setup do
      previous = Application.get_env(:code_my_spec, :provisioning_waits, :real)
      Application.put_env(:code_my_spec, :provisioning_waits, :real)
      on_exit(fn -> Application.put_env(:code_my_spec, :provisioning_waits, previous) end)
      :ok
    end

    # The self-inflicted half of the problem: a record written a moment ago has
    # not reached a public resolver, and asking before it has is what caches the
    # "no" that every later retry then reads instead of the record. The wait
    # happens before the first question, not only between questions.
    test "waits before asking at all" do
      parent = self()

      resolver = fn _url, _headers ->
        send(parent, {:asked, System.monotonic_time(:millisecond)})
        {:ok, %{status: 200, body: %{"Status" => 0, "Answer" => [%{"data" => "192.0.2.10"}]}}}
      end

      started = System.monotonic_time(:millisecond)
      assert Dns.resolution_status("x.astralbi.com", :a, resolver: resolver, settle_ms: 50) ==
               :resolves

      assert_received {:asked, asked_at}

      assert asked_at - started >= 50,
             "expected the first question to wait for the record to propagate"
    end

    test "does not wait when told not to" do
      started = System.monotonic_time(:millisecond)

      assert Dns.resolution_status("x.astralbi.com", :a, resolver: answered("192.0.2.10")) ==
               :resolves

      assert System.monotonic_time(:millisecond) - started < 50,
             "expected no settle by default — a caller that already waited must not wait again"
    end
  end
end
