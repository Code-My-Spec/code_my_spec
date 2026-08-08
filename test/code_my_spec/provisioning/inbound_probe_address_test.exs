defmodule CodeMySpec.Provisioning.InboundProbeAddressTest do
  @moduledoc """
  Which address the inbound step is willing to prove delivery to.

  Resend accepts mail only at addresses configured for a domain, and exposes no
  API to ask which those are. An invented local part is dropped in silence, and
  silence is indistinguishable from a broken inbox.

  The step used to hardcode `setup-probe@<domain>`, which cost most of a day of
  diagnosis: mail to `john@astralbi.com` arrived, mail to
  `setup-probe@astralbi.com` never did, and the step reported the inbox broken.
  A novel local part *did* arrive on a second domain, which sent the
  investigation after Resend outages and our own webhook — that domain simply
  had a catch-all. One sample generalised into the wrong theory while the right
  one had already been discarded.

  ## What is covered here, and what is not

  Only the address decision the step makes **before it calls a provider**: an
  address on another domain can never prove this one's inbox, so the run cannot
  succeed and must not first go and reconfigure Resend.

  The other half — no address at all — deliberately publishes the records first
  (they are needed either way, and MX propagation is the slow part) and pauses
  afterwards. Reaching that point requires stubbing both Resend and Cloudflare,
  because `publish_mx/4` calls `Cloudflare.find_zone/2` with no seam. It is
  **not covered here**. An earlier draft appeared to cover it and did not: with
  no provider connected the run stopped at "resend not connected", so asserting
  the absence of a success was true for a reason that had nothing to do with
  addresses.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Provisioning.Steps

  @domain "inbound-drill.example.com"

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    scope = %{full_scope_fixture() | environment: Environment.new(:local, tmp)}

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{domain: @domain})

    {:ok, scope: %{scope | active_project: project}}
  end

  describe "a probe address on another domain" do
    test "pauses, because delivering there proves nothing about this domain", ctx do
      assert {:paused, message} =
               Steps.run(:inbound, ctx.scope, inbound_probe_to: "john@somewhere-else.example.com")

      assert message =~ "somewhere-else.example.com"
      assert message =~ @domain

      assert message =~ "prove nothing",
             "mail to another domain arrives whether or not this one is configured"
    end

    # A domain that merely *ends with* the project's domain is a different
    # domain. `evil-inbound-drill.example.com` is not a subdomain of
    # `inbound-drill.example.com`, and a bare suffix check would accept it.
    test "is not fooled by a domain that merely ends with this one", ctx do
      assert {:paused, _} =
               Steps.run(:inbound, ctx.scope,
                 inbound_probe_to: "john@evil-inbound-drill.example.com"
               )
    end

    # The anchor. These tests only mean something because the refusal happens
    # before any provider call — otherwise they would be asserting against
    # "resend not connected" and would pass with the check deleted.
    test "refuses before touching the provider", ctx do
      assert {:paused, message} =
               Steps.run(:inbound, ctx.scope, inbound_probe_to: "john@somewhere-else.example.com")

      refute message =~ "not connected",
             "reaching the provider means the address was checked too late to matter"
    end
  end
end
