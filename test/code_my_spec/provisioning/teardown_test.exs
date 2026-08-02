defmodule CodeMySpec.Provisioning.TeardownTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

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

      assert {:ok, ^adopted} = Teardown.resource(scope, adopted),
             "teardown touched a domain setup did not create"
    end

    test "every kind is spared when adopted, not just domains", %{scope: scope} do
      for kind <- ~w(bucket server firewall receiving_domain sending_domain webhook dns_record) do
        r = %{kind: kind, location: "provider/thing", origin: "adopted"}

        assert {:ok, ^r} = Teardown.resource(scope, r),
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
end
