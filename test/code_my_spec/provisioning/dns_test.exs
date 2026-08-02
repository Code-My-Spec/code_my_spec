defmodule CodeMySpec.Provisioning.DnsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Dns

  # These query real public DNS against names that are stable and not ours to
  # break. A stubbed resolver would prove the function calls :inet_res, which
  # is not the thing in doubt — the thing in doubt is whether what a resolver
  # returns matches what a provider claims, and that is the whole reason this
  # module exists.
  @moduletag :live

  describe "resolves?/3" do
    test "true for a name that is published" do
      assert Dns.resolves?("cloudflare.com", :a)
    end

    test "false for a name that is not" do
      refute Dns.resolves?("this-name-does-not-exist-cms-spex.cloudflare.com", :a)
    end

    # The failure this module exists to catch: a provider reporting verified
    # for a record that is no longer published. "Not resolving" has to be a
    # plain false rather than an error, or every caller invents its own
    # handling for a distinction with no consequence.
    test "a lookup that finds nothing is false, not an error" do
      assert Dns.lookup("nx-cms-spex.cloudflare.com", :txt) == []
    end
  end

  describe "mx_records/2" do
    test "returns priority and host together" do
      records = Dns.mx_records("cloudflare.com")

      assert records != []
      assert Enum.all?(records, &(&1 =~ ~r/^\d+ \S+/)),
             "an MX without its priority is not comparable — priority decides which host is used"
    end

    test "is sorted, so two readings of one zone compare equal" do
      assert Dns.mx_records("cloudflare.com") == Enum.sort(Dns.mx_records("cloudflare.com"))
    end
  end
end
