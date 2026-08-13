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
  describe "resolves_publicly?/3" do
    # One-argument stubs on purpose: every one written before there was a second
    # resolver takes a url and nothing else, and adapting them rather than
    # rewriting them is what `req/1` promises.
    test "asks a second resolver when the first has nothing" do
      test_process = self()

      asked = fn url ->
        send(test_process, {:asked, URI.parse(url).host})

        case URI.parse(url).host do
          "dns.google" -> {:ok, %{status: 200, body: %{"Status" => 3}}}
          _ -> {:ok, %{status: 200, body: %{"Answer" => [%{"data" => "1.2.3.4"}]}}}
        end
      end

      assert Dns.resolves_publicly?("published.example.com", :a, resolver: asked)

      assert_received {:asked, "dns.google"}
      assert_received {:asked, "cloudflare-dns.com"}
    end

    # This is now load-bearing rather than cosmetic: a record no resolver
    # returns halts the run at the DNS step, so a single provider's cached
    # negative could stop a setup whose DNS was right and name the record as
    # missing while doing it.
    test "one resolver's silence does not decide it" do
      google_is_behind = fn url ->
        case URI.parse(url).host do
          "dns.google" -> {:ok, %{status: 200, body: %{"Status" => 3}}}
          _ -> {:ok, %{status: 200, body: %{"Answer" => [%{"data" => "178.156.185.52"}]}}}
        end
      end

      assert Dns.resolves_publicly?("uat.example.com", :a, resolver: google_is_behind),
             "a record one resolver has not caught up with still resolves"
    end

    # The path every existing cassette recorded. Asking the second resolver only
    # after the first comes up empty is what keeps those replaying unchanged —
    # a second request on the happy path would have missed in every one of them.
    test "does not ask the second when the first answers" do
      test_process = self()

      answered = fn url ->
        send(test_process, {:asked, URI.parse(url).host})
        {:ok, %{status: 200, body: %{"Answer" => [%{"data" => "1.2.3.4"}]}}}
      end

      assert Dns.resolves_publicly?("published.example.com", :a, resolver: answered)

      assert_received {:asked, "dns.google"}
      refute_received {:asked, "cloudflare-dns.com"}
    end

    test "false only when both are silent" do
      silent = fn _url -> {:ok, %{status: 200, body: %{"Status" => 3}}} end

      refute Dns.resolves_publicly?("nowhere.example.com", :a, resolver: silent)
    end

    # A 400 reads as no answer, and Cloudflare returns exactly that for the JSON
    # endpoint when nothing asks for JSON. Without the header the second opinion
    # would be silent in every case it exists to speak up for.
    test "asks Cloudflare for the format it will actually answer in" do
      test_process = self()

      capture = fn url, headers ->
        send(test_process, {:headers, URI.parse(url).host, headers})
        {:ok, %{status: 200, body: %{"Status" => 3}}}
      end

      refute Dns.resolves_publicly?("nowhere.example.com", :a, resolver: capture)

      assert_received {:headers, "cloudflare-dns.com", headers}
      assert headers[:accept] == "application/dns-json"
    end
  end
end
