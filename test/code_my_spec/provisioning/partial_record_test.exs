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

    # `origin` wins on collision, and this is why. Teardown refuses to delete
    # what it only adopted; letting a retry restate the same resource as
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

    # 3a010015: a server destroyed and rebuilt at a new address kept the old
    # one on record, because the earlier struct won *whole* on collision —
    # not just its `origin`. A rebuilt resource's `identifier` has to be this
    # run's, or a person reading it back (criterion 7969) and teardown's own
    # address comparison both work from an address that belongs to nobody.
    test "a rebuilt resource's identifier is this run's, not the one before it", ctx do
      {:ok, _} =
        Provisioning.run_step(
          ctx.scope,
          :server,
          succeed_with([
            %{
              kind: "server",
              location: "hetzner/uat-box",
              identifier: "5.161.239.73 environment=uat",
              origin: "created"
            }
          ])
        )

      {:ok, _} =
        Provisioning.run_step(ctx.scope, :server,
          verify: fn _, _ -> {:ok, :absent} end,
          execute: fn _, _, _ ->
            {:ok,
             [
               %{
                 kind: "server",
                 location: "hetzner/uat-box",
                 identifier: "49.12.189.154 environment=uat",
                 origin: "created"
               }
             ]}
          end
        )

      assert [%{identifier: "49.12.189.154 environment=uat", origin: "created"}] =
               StepRepository.get(ctx.scope, :server).resources,
             "the box was destroyed and rebuilt at a new address — the record must follow it"
    end

    # The two properties at once, which is what the issue's own DNS record
    # was: `origin: "adopted"` (so teardown keeps sparing it) pointing at a
    # server that was genuinely rebuilt this run (so its address has to be
    # current). Neither property may borrow the other's staleness.
    test "an adopted resource keeps its origin but takes this run's identifier", ctx do
      {:ok, _} =
        Provisioning.run_step(
          ctx.scope,
          :dns,
          succeed_with([
            %{
              kind: "dns_record",
              location: "cloudflare/uat.example.com",
              identifier: "5.161.239.73 environment=uat",
              origin: "adopted"
            }
          ])
        )

      {:ok, _} =
        Provisioning.run_step(ctx.scope, :dns,
          verify: fn _, _ -> {:ok, :absent} end,
          execute: fn _, _, _ ->
            {:ok,
             [
               %{
                 kind: "dns_record",
                 location: "cloudflare/uat.example.com",
                 identifier: "49.12.189.154 environment=uat",
                 origin: "created"
               }
             ]}
          end
        )

      assert [%{identifier: "49.12.189.154 environment=uat", origin: "adopted"}] =
               StepRepository.get(ctx.scope, :dns).resources
    end
  end

  describe "a second walk that finds everything already there" do
    # The satisfied path, which is where the takeover came from. `ensure_*`
    # marks a resource `adopted` when it finds one already present — right for
    # "did I make this on *this* run", wrong for "did this exist before setup
    # ever ran". So a DNS record setup created on the first walk came back
    # adopted on the second, `Teardown.resource/3` spared it, and the server it
    # pointed at was released. Hetzner recycles those addresses (167394ad).
    #
    # `keeping_earlier/3` covers the run path and is tested above; this is the
    # same rule on the path a *repeated* walk takes, where every step verifies
    # satisfied and nothing is executed at all.
    test "a resource an earlier run created stays created when re-verified as adopted", ctx do
      StepRepository.upsert(ctx.scope, :dns, %{
        state: :done,
        position: 5,
        resources: [
          %{kind: "dns_record", location: "cloudflare/uat.example.com", origin: "created"}
        ]
      })

      verify = fn
        _scope, :dns ->
          {:ok, :satisfied,
           [%{kind: "dns_record", location: "cloudflare/uat.example.com", origin: "adopted"}]}

        _scope, _key ->
          {:ok, :absent}
      end

      Provisioning.run_step(ctx.scope, :dns, verify: verify)

      assert [%{origin: "created"}] = StepRepository.get(ctx.scope, :dns).resources,
             "a second walk re-labelled a record setup had created as adopted, " <>
               "which is what makes teardown spare it"
    end

    # The other direction stays refused, and that is not symmetry for its own
    # sake: a step claiming `created` for something Sam had before setup ran is
    # how teardown gets licensed to destroy it.
    test "a resource first seen as adopted is not promoted by a later created claim", ctx do
      StepRepository.upsert(ctx.scope, :dns, %{
        state: :done,
        position: 5,
        resources: [
          %{kind: "dns_record", location: "cloudflare/apex.example.com", origin: "adopted"}
        ]
      })

      verify = fn
        _scope, :dns ->
          {:ok, :satisfied,
           [%{kind: "dns_record", location: "cloudflare/apex.example.com", origin: "created"}]}

        _scope, _key ->
          {:ok, :absent}
      end

      Provisioning.run_step(ctx.scope, :dns, verify: verify)

      assert [%{origin: "adopted"}] = StepRepository.get(ctx.scope, :dns).resources,
             "a later run claimed ownership of a record it had only adopted"
    end
  end

  describe "a second run that adds an environment" do
    # The shape criterion 8156 provisions: UAT stands alone, then production
    # arrives on its own box. The second run succeeds and returns production's
    # server, so replacing on success dropped UAT's.
    #
    # This is not hypothetical either. After the error path was fixed, a
    # re-recording still leaked: teardown deleted server 160399007 (prod) and
    # left 160398981 (`spex-story966-criterion8156-uat`) running, because UAT
    # was no longer in the list it reads. Succeeding is not the same as knowing
    # everything.
    test "keeps the first environment's server, so teardown removes both", ctx do
      {:ok, _} =
        Provisioning.run_step(
          ctx.scope,
          :server,
          succeed_with([%{kind: "server", location: "hetzner/app-uat", origin: "created"}])
        )

      {:ok, _} =
        Provisioning.run_step(
          ctx.scope,
          :server,
          succeed_with([%{kind: "server", location: "hetzner/app-prod", origin: "created"}])
        )

      assert locations(ctx.scope, :server) == ["hetzner/app-prod", "hetzner/app-uat"],
             "a run that adds prod must not erase uat — teardown reads this list"
    end
  end

  describe "records that describe the run rather than a resource" do
    # Merging is right for a server, which outlives the run that made it, and
    # wrong for a deploy phase, which does not. Keeping phases broke criterion
    # 8008: a deploy whose migration fails must never swap traffic, and the
    # page showed a swap timestamp belonging to the successful deploy before
    # it. Nothing had swapped — the record had stopped being about this run.
    test "a later run's phases replace an earlier run's", ctx do
      {:ok, _} =
        Provisioning.run_step(
          ctx.scope,
          :deploy,
          succeed_with([
            %{kind: "server", location: "hetzner/box", origin: "created"},
            %{kind: "deploy_phase", location: "migrate", identifier: "t1"},
            %{kind: "deploy_phase", location: "swap", identifier: "t1"},
            %{kind: "live_version", location: "new"}
          ])
        )

      # The next deploy fails before it can swap.
      Provisioning.run_step(ctx.scope, :deploy,
        verify: fn _, _ -> {:ok, :absent} end,
        execute: fn _, _, _ ->
          {:error, "migration failed",
           [
             %{kind: "deploy_phase", location: "migrate", identifier: "t2"},
             %{kind: "live_version", location: "previous"}
           ]}
        end
      )

      kinds = StepRepository.get(ctx.scope, :deploy).resources

      refute Enum.any?(kinds, &(&1.kind == "deploy_phase" and &1.location == "swap")),
             "the earlier run's swap must not survive into a run that never swapped"

      assert Enum.any?(kinds, &(&1.kind == "server")),
             "the box the earlier run made still has to be findable for teardown"

      assert [%{location: "previous"}] = Enum.filter(kinds, &(&1.kind == "live_version"))
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
