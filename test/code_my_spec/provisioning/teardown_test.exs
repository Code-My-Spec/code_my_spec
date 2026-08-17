defmodule CodeMySpec.Provisioning.TeardownTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import ExUnit.CaptureLog

  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.{StepRepository, Teardown}

  setup do
    %{scope: full_scope_fixture()}
  end

  describe "the destructive surface stays deliberate" do
    # The reason teardown is its own module. `run/3` is meant to be run
    # unattended, and a destroy function sitting next to it is one typo from
    # a very bad afternoon.
    test "Provisioning itself still exposes nothing that destroys" do
      exported = Provisioning.__info__(:functions) |> Keyword.keys() |> Enum.map(&to_string/1)

      for word <- ~w(destroy teardown delete remove) do
        refute Enum.any?(exported, &String.contains?(&1, word)),
               "Provisioning exposes something matching #{word} — teardown belongs in Teardown"
      end
    end
  end

  describe "adopted resources are never destroyed" do
    # This is the incident, as a test. `ensure_domain` adopts an existing
    # sending domain and records it, and teardown removed it — deleting a
    # long-standing production domain. Resend fixes capabilities at creation,
    # so the recreate that followed silently dropped inbound mail.
    #
    # "Only remove what the step recorded" was not a sufficient safety
    # property, because a step records what it adopted too.
    test "a sending domain setup merely found is left alone", %{scope: scope} do
      adopted = %{
        kind: "sending_domain",
        location: "resend/example.com",
        identifier: "prod:abc",
        origin: "adopted"
      }

      # `:skipped`, not `:ok`. Sparing it is still the claim; saying so in the
      # return is what stops the summary counting it as removed — a teardown
      # reported 14/14 complete while a live DNS record it had skipped still
      # pointed at a released address (167394ad).
      assert {:skipped, ^adopted} = Teardown.resource(scope, adopted),
             "teardown touched a domain setup did not create"
    end

    test "every kind is spared when adopted, not just domains", %{scope: scope} do
      for kind <- ~w(bucket server firewall receiving_domain sending_domain webhook dns_record) do
        r = %{kind: kind, location: "provider/thing", origin: "adopted"}

        assert {:skipped, ^r} = Teardown.resource(scope, r),
               "an adopted #{kind} was not spared"
      end
    end

    # The default matters as much as the guard: a resource recorded before
    # `origin` existed, or by a provider that forgot to set it, must read as
    # adopted rather than as fair game.
    test "a resource with no recorded origin defaults to adopted" do
      assert %{origin: "adopted"} = %CodeMySpec.Provisioning.Resource{}
    end
  end

  # The one exception, and the reason the drill mattered. Sparing an adopted
  # resource preserves something Sam had; sparing a DNS record aimed at a
  # server this project is releasing preserves nothing and manufactures a
  # subdomain takeover — Hetzner recycles the address, the name keeps
  # resolving, and it resolves to a stranger's machine under Sam's own domain
  # (167394ad). The next build then reads the record it should have removed as
  # a live site and refuses to repoint it (7f999888).
  describe "an adopted record aimed at a server we own" do
    defp uat, do: %{name: "uat", host: "uat.astralbi.com", ip: "49.12.189.154"}

    test "is removed rather than spared", %{scope: scope} do
      record = %{
        kind: "dns_record",
        location: "cloudflare/uat.astralbi.com",
        identifier: "49.12.189.154 environment=uat",
        origin: "adopted"
      }

      log =
        capture_log(fn ->
          # Not `{:ok, _}`: removal itself is the Cloudflare clause, which has
          # no credential here and reports it. What is under test is the
          # decision in front of it, and `:skipped` is the outcome that says
          # teardown walked past a record still pointing at a released box.
          refute match?(
                   {:skipped, _},
                   Teardown.resource(scope, record, project_environments: [uat()])
                 ),
                 "an adopted record at an environment's own host must not be spared"
        end)

      assert log =~ "uat.astralbi.com"
    end

    # The case QA on story 851 actually found, and the reason this is matched on
    # the host rather than on the recorded address. The uat box was at
    # 49.12.189.154 — in the environment row, in Hetzner, and in `dig` — while
    # the recorded resource still carried 5.161.239.73 from the run before. An
    # address comparison misses exactly the live instance of the takeover it
    # was written to catch.
    test "is removed even when the recorded address went stale", %{scope: scope} do
      record = %{
        kind: "dns_record",
        location: "cloudflare/uat.astralbi.com",
        identifier: "5.161.239.73 environment=uat",
        origin: "adopted"
      }

      capture_log(fn ->
        refute match?(
                 {:skipped, _},
                 Teardown.resource(scope, record, project_environments: [uat()])
               ),
               "a stale identifier must not be the reason a dangling record survives"
      end)
    end

    # The narrowness is the point. "Ignore origin for DNS records" would be the
    # easy version and it deletes an apex a customer already had, pointing at
    # Cloudflare's proxy or at a site hosted somewhere else — exactly the
    # resource the adopted rule exists to spare.
    test "a record at a name no environment uses is still spared", %{scope: scope} do
      record = %{
        kind: "dns_record",
        location: "cloudflare/blog.astralbi.com",
        identifier: "172.64.80.1 environment=prod",
        origin: "adopted"
      }

      assert {:skipped, ^record} =
               Teardown.resource(scope, record, project_environments: [uat()])
    end

    test "a record that recorded no target is spared", %{scope: scope} do
      record = %{kind: "dns_record", location: "cloudflare/blog.astralbi.com", origin: "adopted"}

      assert {:skipped, ^record} =
               Teardown.resource(scope, record, project_environments: [uat()])
    end

    # Only the record. The address belongs to a server, and a server recorded
    # adopted is one setup found running — destroying it is the original
    # incident in a new place.
    test "an adopted server at one of those addresses is still spared", %{scope: scope} do
      record = %{
        kind: "server",
        location: "hetzner/qa-fixture-project-uat",
        identifier: "49.12.189.154 environment=uat",
        origin: "adopted"
      }

      assert {:skipped, ^record} =
               Teardown.resource(scope, record, project_environments: [uat()])
    end
  end

  describe "it removes only what a step recorded" do
    test "a step that recorded nothing removes nothing", %{scope: scope} do
      StepRepository.upsert(scope, :storage, %{state: :done, position: 9, resources: []})

      assert {:ok, []} = Teardown.step(scope, :storage)
    end

    test "a step that never ran removes nothing", %{scope: scope} do
      assert {:ok, []} = Teardown.step(scope, :storage)
    end

    # The safety property, stated as a test rather than a comment: there is no
    # argument that makes this search for resources by name or pattern. A
    # teardown that could would eventually find production.
    test "takes its targets from the recorded resources, not from a pattern", %{scope: scope} do
      source = File.read!("lib/code_my_spec/provisioning/teardown.ex")

      refute source =~ ~r/list_buckets.*\|>.*filter.*prod/i,
             "teardown appears to search for resources rather than read what was recorded"

      # Every clause dispatches on a recorded resource map.
      assert source =~ "def resource(%Scope{} = scope, %{kind:"

      _ = scope
    end
  end

  describe "a teardown reports only what it removed" do
    # The drill's teardown said "14/14, everything recorded came down" in 9.5
    # seconds. One of the fourteen was a `dns_record` marked adopted: skipped,
    # counted as removed, and still resolving to an address Hetzner had just
    # released back into its pool. The ordering guarantee in
    # `environment/3`'s moduledoc is about *when* a record is removed and
    # cannot help when it is not removed at all (167394ad).
    test "a skipped adoption is not counted among the removed", %{scope: scope} do
      StepRepository.upsert(scope, :dns, %{
        state: :done,
        position: 5,
        resources: [
          %{kind: "dns_record", location: "cloudflare/uat.example.com", origin: "adopted"}
        ]
      })

      assert {:ok, removed} = Teardown.step(scope, :dns)

      assert removed == [],
             "a resource teardown skipped was reported as removed: #{inspect(removed)}"
    end
  end

  describe "resources with nothing to remove provider-side" do
    # These live in the project's own repository or in our encrypted store,
    # and both go away with the project. Reporting them as removed is honest;
    # reporting them as failures would make every teardown look broken.
    test "age keys, credentials and proofs report clean", %{scope: scope} do
      for kind <- ~w(age_key callback_credential commit certificate retention restore_proof
                     content deployment monitor dump repository) do
        resource = %{kind: kind, location: "somewhere", identifier: nil}

        assert {:ok, ^resource} = Teardown.resource(scope, resource),
               "#{kind} should report clean rather than failing"
      end
    end

    # Registration costs money and is not refundable. This is the one place
    # the original setup-only rule still holds outright.
    test "a registered domain is never destroyed", %{scope: scope} do
      resource = %{kind: "domain", location: "cloudflare/example.com", identifier: nil}

      assert {:ok, ^resource} = Teardown.resource(scope, resource)
    end
  end

  describe "an unknown resource is reported, not ignored" do
    # Only for resources setup *created*. One it merely adopted is spared by
    # the guard above and is not a leak — we did not make it, so leaving it is
    # correct rather than an omission.
    @tag :capture_log
    test "a created kind with no rule fails rather than reporting clean", %{scope: scope} do
      resource = %{
        kind: "something_new",
        location: "provider/thing",
        identifier: nil,
        origin: "created"
      }

      assert {:error, ^resource} = Teardown.resource(scope, resource)
    end

    # The whole point of the error case: a step whose resources could not all
    # be removed says so, naming what survived, because silence here means
    # somebody pays for a resource nobody remembers.
    @tag :capture_log
    test "a step naming an unremovable resource reports what was left behind", %{scope: scope} do
      StepRepository.upsert(scope, :storage, %{
        state: :done,
        position: 9,
        resources: [
          %{kind: "something_new", location: "provider/thing", origin: "created"}
        ]
      })

      assert {:error, {:left_behind, [%{kind: "something_new"}]}} =
               Teardown.step(scope, :storage)
    end
  end

  describe "a torn-down step stops being a done step" do
    # 1040172a, as a test. Teardown removed the provider resources and never
    # wrote to the step row, so the step stayed `done` carrying every resource
    # it had recorded — and `verify/3` reads those.
    #
    # On the drill that meant an `inbound_proof` survived two teardowns and
    # then satisfied a rebuilt environment in 0.2s, against servers that no
    # longer existed, overriding a real delivery failure ten minutes old. The
    # proof of an environment must not outlive the environment.
    test "its recorded resources are forgotten", %{scope: scope} do
      StepRepository.upsert(scope, :inbound, %{
        state: :done,
        position: 9,
        resources: [
          %{kind: "inbound_proof", location: "inbox@example.com", origin: "created"}
        ]
      })

      assert {:ok, _} = Teardown.step(scope, :inbound)

      assert %{state: :not_started, resources: []} = StepRepository.get(scope, :inbound)
    end

    # Only on full success. A step that left something behind still owns it,
    # and forgetting that is how a leak becomes invisible — the opposite of
    # what teardown's error path exists to do.
    @tag :capture_log
    test "a step that left something behind keeps what it still owns", %{scope: scope} do
      StepRepository.upsert(scope, :storage, %{
        state: :done,
        position: 9,
        resources: [
          %{kind: "something_new", location: "provider/thing", origin: "created"}
        ]
      })

      assert {:error, {:left_behind, _}} = Teardown.step(scope, :storage)

      assert %{state: :done, resources: [%{kind: "something_new"}]} =
               StepRepository.get(scope, :storage)
    end
  end
end
