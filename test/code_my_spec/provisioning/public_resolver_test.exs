defmodule CodeMySpec.Provisioning.PublicResolverTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Dns

  # Stubbed rather than live, and in its own file for that reason: `dns_test.exs`
  # is `@moduletag :live` because what it doubts is what real DNS says. What
  # these doubt is *how many resolvers get asked*, which no real lookup can
  # demonstrate on demand — the interesting case only exists while one provider
  # holds a stale cache.
  #
  # It is not hypothetical. Measured during a drill, on a record that had just
  # been written:
  #
  #     dig +short @8.8.8.8 uat.spex-drill.legwork.ca A   ->  (nothing)
  #     dig +short @1.1.1.1 uat.spex-drill.legwork.ca A   ->  178.156.185.52
  #
  # `dns.google` returned NXDOMAIN for a record that was published, correct and
  # visible to the rest of the internet. Asking it alone, the setup reported the
  # record as missing.
  @google "dns.google"
  @cloudflare "cloudflare-dns.com"

  describe "resolves_publicly?/3" do
    test "asks a second resolver when the first has nothing" do
      assert Dns.resolves_publicly?("published.example.com", :a,
               resolver: resolver(%{@google => silent(), @cloudflare => answering("1.2.3.4")})
             )

      assert_received {:asked, @google}
      assert_received {:asked, @cloudflare}
    end

    # This is now load-bearing rather than cosmetic: a record no resolver
    # returns halts the run at the DNS step, so a single provider's cached
    # negative could stop a setup whose DNS was right and name the record as
    # missing while doing it.
    test "one resolver's silence does not decide it" do
      assert Dns.resolves_publicly?("uat.example.com", :a,
               resolver:
                 resolver(%{@google => silent(), @cloudflare => answering("178.156.185.52")})
             ),
             "a record one resolver has not caught up with still resolves"
    end

    # The path every existing cassette recorded. Asking the second resolver only
    # after the first comes up empty is what keeps those replaying unchanged — a
    # second request on the happy path would have missed in every one of them.
    #
    # The table names only Google, so asking Cloudflare raises rather than
    # quietly returning a default. The `refute_received` states the claim; the
    # missing entry is what enforces it.
    test "does not ask the second when the first answers" do
      assert Dns.resolves_publicly?("published.example.com", :a,
               resolver: resolver(%{@google => answering("1.2.3.4")})
             )

      assert_received {:asked, @google}
      refute_received {:asked, @cloudflare}
    end

    test "false only when both are silent" do
      refute Dns.resolves_publicly?("nowhere.example.com", :a,
               resolver: resolver(%{@google => silent(), @cloudflare => silent()})
             )
    end

    # A 400 reads as no answer, and Cloudflare returns exactly that for the JSON
    # endpoint when nothing asks for JSON. Without the header the second opinion
    # would be silent in every case it exists to speak up for.
    test "asks Cloudflare for the format it will actually answer in" do
      refute Dns.resolves_publicly?("nowhere.example.com", :a,
               resolver:
                 recording_headers(%{@google => silent(), @cloudflare => silent()})
             )

      assert_received {:headers, @cloudflare, headers}
      assert headers[:accept] == "application/dns-json"
    end
  end

  # Answers from a fixed table and reports what it was asked.
  #
  # `Map.fetch!` rather than a default: a resolver the test did not plan for
  # should fail loudly, not quietly receive whatever the fallback happens to be.
  # The stub runs inside the test process, so `self()` is the test.
  defp resolver(bodies) do
    fn url -> answer(bodies, url, {:asked, host(url)}) end
  end

  # One-argument stubs are the ones written before there was a second resolver;
  # `req/1` adapts them rather than rejecting them, and this is the two-argument
  # form for the one claim that is about the headers.
  defp recording_headers(bodies) do
    fn url, headers -> answer(bodies, url, {:headers, host(url), headers}) end
  end

  defp answer(bodies, url, message) do
    send(self(), message)
    {:ok, %{status: 200, body: Map.fetch!(bodies, host(url))}}
  end

  defp host(url), do: URI.parse(url).host

  # NXDOMAIN: a well-formed answer that carries no records.
  defp silent, do: %{"Status" => 3}

  defp answering(data), do: %{"Answer" => [%{"data" => data}]}
end
