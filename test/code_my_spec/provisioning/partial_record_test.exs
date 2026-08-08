defmodule CodeMySpec.Provisioning.PartialRecordTest do
  @moduledoc """
  Whether a step that fails on a retry still remembers what an earlier run
  created.

  `resources` is an `embeds_many` with `on_replace: :delete`, so recording a
  list replaces the previous one outright. The failure paths record only what
  *this* run managed to make before it stopped — which meant a retry that got
  nowhere erased the record of everything the first run had built.

  Teardown works from that record, so what it forgets is precisely what leaks.
  This is not hypothetical: a recording of criterion 8156 left a real Hetzner
  server, `spex-story966-criterion8156-uat`, running on the account. Run one
  created and recorded the box; run two errored on a cassette miss having made
  only an ssh key; the box became invisible and had to be deleted by hand.

  The irony worth preserving: the partial-record path exists *because* a
  failure that records nothing leaks by construction. It recorded something,
  and the something was the problem.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.StepRepository

  setup do
    {:ok, scope: full_scope_fixture()}
  end

  defp succeed_with(resources) do
    [verify: fn _, _ -> {:ok, :absent} end, execute: fn _, _, _ -> {:ok, resources} end]
  end

  defp locations(scope, key) do
    StepRepository.get(scope, key).resources |> Enum.map(& &1.location) |> Enum.sort()
  end

  describe "a retry that errors partway" do
    test "keeps what the earlier run recorded, and adds its own", ctx do
      {:ok, _} =
        Provisioning.run_step(
          ctx.scope,
          :server,
          succeed_with([%{kind: "server", location: "hetzner/uat-box", origin: "created"}])
        )

      Provisioning.run_step(ctx.scope, :server,
        verify: fn _, _ -> {:ok, :absent} end,
        execute: fn _, _, _ ->
          {:error, "cassette miss",
           [%{kind: "ssh_key", location: "hetzner/key", origin: "created"}]}
        end
      )

      assert locations(ctx.scope, :server) == ["hetzner/key", "hetzner/uat-box"],
             "the box from the first run must still be findable, or teardown leaks it"
    end

    test "does not duplicate a resource it already knew about", ctx do
      server = %{kind: "server", location: "hetzner/uat-box", origin: "created"}

      {:ok, _} = Provisioning.run_step(ctx.scope, :server, succeed_with([server]))

      Provisioning.run_step(ctx.scope, :server,
        verify: fn _, _ -> {:ok, :absent} end,
        execute: fn _, _, _ -> {:error, "failed again", [server]} end
      )

      assert locations(ctx.scope, :server) == ["hetzner/uat-box"]
    end

    # Earlier entries win on collision, and this is why. Teardown refuses to
    # delete what it only adopted; letting a retry restate the same resource as
    # `created` would license it to destroy something Sam had before setup ran.
    test "cannot re-label an adopted resource as created", ctx do
      {:ok, _} =
        Provisioning.run_step(
          ctx.scope,
          :domain,
          succeed_with([%{kind: "domain", location: "cloudflare/sam.com", origin: "adopted"}])
        )

      Provisioning.run_step(ctx.scope, :domain,
        verify: fn _, _ -> {:ok, :absent} end,
        execute: fn _, _, _ ->
          {:error, "later failure",
           [%{kind: "domain", location: "cloudflare/sam.com", origin: "created"}]}
        end
      )

      assert [%{origin: "adopted"}] = StepRepository.get(ctx.scope, :domain).resources
    end
  end

  describe "a retry that pauses partway" do
    # The pause path records resources for the same reason the error path does:
    # the email step registers a real sending domain at Resend and then waits
    # for verification. A pause that dropped them would leak identically.
    test "keeps what the earlier run recorded", ctx do
      {:ok, _} =
        Provisioning.run_step(
          ctx.scope,
          :email,
          succeed_with([
            %{kind: "sending_domain", location: "resend/uat.sam.com", origin: "created"}
          ])
        )

      Provisioning.run_step(ctx.scope, :email,
        verify: fn _, _ -> {:ok, :absent} end,
        execute: fn _, _, _ ->
          {:paused, "waiting on verification",
           [%{kind: "sending_record", location: "cloudflare/send.sam.com", origin: "created"}]}
        end
      )

      assert locations(ctx.scope, :email) == [
               "cloudflare/send.sam.com",
               "resend/uat.sam.com"
             ]
    end
  end
end
