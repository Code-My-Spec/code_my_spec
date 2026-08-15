defmodule Mix.Tasks.Cms.ProvisioningLeaksMarkerTest do
  @moduledoc """
  What the leak sweep recognises as ours.

  This is the only thing standing between a spex run and a live resource
  nobody is watching, and every gap in it has been found the same way: a
  resource sitting in a real zone, reported by the sweep as real.

  Two such gaps so far, both in the criterion half of the pattern. It matched
  only `c8000`-`c8099`, so every criterion outside that range was invisible;
  and it demanded the label end immediately after the digits, so a criterion
  that suffixes its host per environment slipped past. Two live Resend sending
  domains and four DNS records were behind the second one.

  The cases below are the actual names involved, not invented ones.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cms.ProvisioningLeaks

  describe "names the sweep must claim" do
    test "a criterion label, plain" do
      assert ProvisioningLeaks.leaked?("c8025.astralbi.com")
    end

    # The one that got away: one host per environment, distinguished by a
    # letter after the criterion.
    test "a criterion label with an environment suffix" do
      assert ProvisioningLeaks.leaked?("c8025b.astralbi.com")
      assert ProvisioningLeaks.leaked?("send.c8025b.astralbi.com")
    end

    # `c80\\d{2}` could never see these. 8156, 8182 and 8233 are all real
    # criteria that provision real things.
    test "criteria outside the 8000s" do
      assert ProvisioningLeaks.leaked?("c8156.astralbi.com")
      assert ProvisioningLeaks.leaked?("c8233.astralbi.com")
      assert ProvisioningLeaks.leaked?("c1963.astralbi.com")
    end

    test "a spex-prefixed name, which is a label prefix rather than a whole label" do
      assert ProvisioningLeaks.leaked?("spex-story969-criterion8027")
      assert ProvisioningLeaks.leaked?("send.spex-story969-criterion8027.astralbi.com")
    end

    test "a bare resource name with no domain at all" do
      assert ProvisioningLeaks.leaked?("spex-story972-criterion8039-registry-uat")
    end
  end

  describe "build servers, which are named after a commit and not a project" do
    # `builder-24b93652c4ab` outlived a deploy that died mid-build and the sweep
    # reported the account clean, because nothing in the marker describes a name
    # made from a git ref. Every path in `Builder` destroys its server, so one
    # that is still here is leaked by definition.
    test "a builder is a leak" do
      assert ProvisioningLeaks.leaked?("builder-24b93652c4ab")
      assert ProvisioningLeaks.leaked?("builder-a2942f0ce5b3")
    end

    # The prefix is anchored, or a real host that happens to build things would
    # be swept.
    test "a name that merely contains the word is not" do
      refute ProvisioningLeaks.leaked?("our-builder-box")
      refute ProvisioningLeaks.leaked?("buildermatic.example.com")
    end
  end

  describe "names the sweep must never claim" do
    # These are John's. Sweeping one would delete a live server.
    test "the protected servers" do
      refute ProvisioningLeaks.leaked?("fuellytics")
      refute ProvisioningLeaks.leaked?("fuellytics-prod")
    end

    test "real domains" do
      refute ProvisioningLeaks.leaked?("codemyspec.com")
      refute ProvisioningLeaks.leaked?("astralbi.com")
      refute ProvisioningLeaks.leaked?("send.astralbi.com")
      refute ProvisioningLeaks.leaked?("get-ai-traffic.com")
    end

    # The left boundary earns its keep here: the letters appear, but not at the
    # start of a label.
    test "a real name that merely contains the marker's letters" do
      refute ProvisioningLeaks.leaked?("abc8025.example.com")
      refute ProvisioningLeaks.leaked?("myspex-thing.example.com")
    end

    # The drill keeps its environment between runs on purpose, and names it
    # `spex-drill-*`, so the `spex-` prefix claimed it. The sweep reported a
    # live 14-step environment as leaked and `--delete` would have released
    # its servers while leaving the DNS pointing at the addresses.
    test "the drill's environment, which is deliberate and long-lived" do
      refute ProvisioningLeaks.leaked?("spex-drill-uat")
      refute ProvisioningLeaks.leaked?("spex-drill-prod")
    end

    # Both separators: Hetzner resources join with `-`, DNS with `.`. A rule
    # written for one form sweeps the other.
    test "the drill's DNS, which joins with a dot rather than a dash" do
      refute ProvisioningLeaks.leaked?("spex-drill.earwitness.app")
      refute ProvisioningLeaks.leaked?("uat.spex-drill.earwitness.app")
      refute ProvisioningLeaks.leaked?("resend._domainkey.spex-drill.earwitness.app")
    end

    # And the exclusion is anchored too, or a genuine spex resource that
    # happens to carry the word goes unswept.
    test "a spex resource that merely mentions drilling is still a leak" do
      assert ProvisioningLeaks.leaked?("spex-drilling-rig")
      assert ProvisioningLeaks.leaked?("spex-story841-drill.astralbi.com")
    end
  end
end
