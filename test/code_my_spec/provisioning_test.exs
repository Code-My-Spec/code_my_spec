defmodule CodeMySpec.ProvisioningTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.{Sequence, StepRepository}

  doctest Sequence, only: [for_options: 1]

  setup do
    %{scope: full_scope_fixture()}
  end

  # Every step succeeds; nothing is already provisioned.
  defp always_absent, do: fn _scope, _key -> {:ok, :absent} end
  defp succeeds, do: fn _scope, _key, _opts -> {:ok, []} end

  describe "the sequence" do
    # Criterion 8182 / rule 4: CI publishes the image the deploy pulls, so a
    # deploy with no remote has nothing to build from.
    test "the repository comes before the deploy" do
      keys = Sequence.keys()

      assert Enum.find_index(keys, &(&1 == :repository)) <
               Enum.find_index(keys, &(&1 == :deploy)),
             "the remote must exist before the first build needs it"
    end

    test "the repository is first overall" do
      assert List.first(Sequence.keys()) == :repository
    end

    # Certificate issuance resolves the name, so DNS has to land first.
    test "dns comes before tls" do
      keys = Sequence.keys()
      assert Enum.find_index(keys, &(&1 == :dns)) < Enum.find_index(keys, &(&1 == :tls))
    end

    # Content and widget are both proven against the running site.
    test "the deploy comes before what is proven against it" do
      keys = Sequence.keys()
      deploy = Enum.find_index(keys, &(&1 == :deploy))

      assert deploy < Enum.find_index(keys, &(&1 == :content))
      assert deploy < Enum.find_index(keys, &(&1 == :widget))
    end
  end

  describe "options subtract without reordering" do
    # Criterion 7968: a step Sam turned off is absent from the run, not
    # present and skipped — a skipped step still reads as part of the plan.
    test "a disabled option's steps are absent entirely" do
      keys = Sequence.for_options([:email]) |> Enum.map(& &1.key)

      assert :email in keys
      refute :storage in keys
      refute :widget in keys
    end

    test "the surviving steps keep their relative order" do
      all = Sequence.keys()
      filtered = Sequence.for_options([:domain, :content]) |> Enum.map(& &1.key)

      assert filtered == Enum.filter(all, &(&1 in filtered))
    end

    test "unconditional steps survive every option set" do
      keys = Sequence.for_options([]) |> Enum.map(& &1.key)

      assert :repository in keys
      assert :server in keys
      assert :deploy in keys
    end
  end

  describe "plan/2" do
    # Criterion 7959: Sam sees the whole plan before anything runs.
    test "shows every included step with a state, before anything has run", %{scope: scope} do
      plan = Provisioning.plan(scope, [])

      assert length(plan) > 0
      assert Enum.all?(plan, &(&1.state == :not_started))
      assert Enum.all?(plan, &is_binary(&1.why))
    end

    test "reflects persisted state for steps that have run", %{scope: scope} do
      StepRepository.upsert(scope, :repository, %{state: :done, position: 0})

      plan = Provisioning.plan(scope, [])
      repository = Enum.find(plan, &(&1.key == :repository))

      assert repository.state == :done
    end
  end

  describe "run/3 halts rather than pressing on" do
    # Criterion 7961: pressing on builds later steps on a broken foundation.
    test "a failing step stops the run and leaves the rest not started", %{scope: scope} do
      execute = fn _scope, key, _opts ->
        case key do
          :repository -> {:ok, []}
          :server -> {:error, "no capacity"}
          _ -> {:ok, []}
        end
      end

      result = Provisioning.run(scope, [], verify: always_absent(), execute: execute)

      assert result.halted_at == :server
      assert result.reason =~ "no capacity"

      # Only the steps up to and including the failure ran.
      assert Enum.map(result.steps, & &1.key) == [:repository, :server]

      # And the deploy — which comes after — was never recorded.
      assert StepRepository.get(scope, :deploy) == nil
    end

    # Pausing is not failure, but it is not progress either, and what follows
    # still depends on it.
    test "a paused step halts the run the same way", %{scope: scope} do
      execute = fn _scope, key, _opts ->
        case key do
          :repository -> {:paused, "Register the domain in the dashboard, then resume."}
          _ -> {:ok, []}
        end
      end

      result = Provisioning.run(scope, [], verify: always_absent(), execute: execute)

      assert result.halted_at == :repository
      assert StepRepository.get(scope, :repository).state == :paused
      assert StepRepository.get(scope, :server) == nil
    end

    test "an unbroken run reaches the end", %{scope: scope} do
      result = Provisioning.run(scope, [], verify: always_absent(), execute: succeeds())

      assert result.halted_at == nil
      assert Enum.map(result.steps, & &1.key) == Sequence.for_options([]) |> Enum.map(& &1.key)
    end
  end

  describe "state is checked against the provider, not remembered" do
    # Criterion 7964: a resource deleted behind setup's back is rebuilt, not
    # skipped. If run/3 filtered on state == :done, a stale row would be
    # permanent — skipped because it says done, and never re-checked.
    test "a step marked done whose resource is gone is run again", %{scope: scope} do
      StepRepository.upsert(scope, :repository, %{state: :done, position: 0})

      {:ok, ran} = Agent.start_link(fn -> [] end)

      execute = fn _scope, key, _opts ->
        Agent.update(ran, &[key | &1])
        {:ok, []}
      end

      Provisioning.run(scope, [], verify: always_absent(), execute: execute)

      assert :repository in Agent.get(ran, & &1),
             "expected a step whose resource is absent to be rebuilt despite a done row"
    end

    # Criterion 7965: running a step twice leaves one of everything.
    test "a step whose resource still exists is not run again", %{scope: scope} do
      verify = fn _scope, key ->
        case key do
          :repository -> {:ok, :satisfied, [%{kind: "repository", location: "github/sam/thing"}]}
          _ -> {:ok, :absent}
        end
      end

      execute = fn _scope, key, _opts ->
        refute key == :repository, "re-ran a step whose resource already existed"
        {:ok, []}
      end

      Provisioning.run(scope, [], verify: verify, execute: execute)

      assert StepRepository.get(scope, :repository).state == :done
    end
  end

  describe "resume/3" do
    # Criterion 7963: steps that already succeeded are not re-executed —
    # re-running from the top would re-provision servers and re-charge for
    # domains.
    test "picks up after the steps already done", %{scope: scope} do
      StepRepository.upsert(scope, :repository, %{state: :done, position: 0})
      StepRepository.upsert(scope, :server, %{state: :done, position: 1})

      {:ok, ran} = Agent.start_link(fn -> [] end)

      execute = fn _scope, key, _opts ->
        Agent.update(ran, &[key | &1])
        {:ok, []}
      end

      Provisioning.resume(scope, [], verify: always_absent(), execute: execute)

      already_done = Agent.get(ran, & &1)
      refute :repository in already_done
      refute :server in already_done
      assert :deploy in already_done
    end

    # Criterion 7967: returning is not the same as having done the errand.
    test "a paused step is re-verified rather than assumed complete", %{scope: scope} do
      StepRepository.upsert(scope, :repository, %{
        state: :paused,
        position: 0,
        paused_instructions: "Go register it."
      })

      {:ok, verified} = Agent.start_link(fn -> [] end)

      verify = fn _scope, key ->
        Agent.update(verified, &[key | &1])
        {:ok, :absent}
      end

      Provisioning.resume(scope, [], verify: verify, execute: succeeds())

      assert :repository in Agent.get(verified, & &1),
             "expected resuming to re-check the paused step against the provider"
    end
  end

  describe "escalation/1" do
    # Criterion 7962: a generic "the domain step failed" tells the agent
    # nothing. The provider's own words name the missing permission.
    test "carries the step, the attempt and the provider's own error", %{scope: scope} do
      execute = fn _scope, _key, _opts ->
        {:error, "Authentication error: token lacks Registrar write permission"}
      end

      Provisioning.run(scope, [], verify: always_absent(), execute: execute)

      escalation = scope |> StepRepository.get(:repository) |> Provisioning.escalation()

      assert escalation.step == :repository
      assert escalation.attempted =~ "repository"
      assert escalation.provider_error =~ "Registrar write permission"
      assert escalation.state == :errored
    end
  end

  describe "setup only" do
    # The context deliberately exposes nothing that destroys. The agent path
    # exists for repair; a routine that can tear down is one nobody runs
    # unattended.
    test "exposes no teardown function" do
      exported = Provisioning.__info__(:functions) |> Keyword.keys() |> Enum.map(&to_string/1)

      refute Enum.any?(exported, &String.contains?(&1, "destroy"))
      refute Enum.any?(exported, &String.contains?(&1, "teardown"))
      refute Enum.any?(exported, &String.contains?(&1, "delete"))
    end
  end

  describe "the sequence actually reaches the providers" do
    # Regression guard. execute_step/3 was a stub returning "not wired" for
    # every step while @runners claimed each one had a module — the map read
    # as wiring and nothing dispatched through it. These assert the real path
    # without injecting an execute function, which is what made the stub
    # invisible: every existing test passed its own executor.
    test "a step with no provider names itself rather than reporting done", %{scope: scope} do
      assert {:halt, row, reason} = Provisioning.run_step(scope, :backups, [])

      assert row.state == :errored
      assert reason =~ "not_implemented"
      assert reason =~ "backups"
    end

    test "an unimplemented step never reports done", %{scope: scope} do
      for key <- [:backups, :storage, :tls, :inbound, :callback_credential] do
        {:halt, row, _} = Provisioning.run_step(scope, key, [])

        refute row.state == :done,
               "#{key} has no provider but reported done — that is the failure this context exists to prevent"
      end
    end

    # The GitHub path is real: no integration on the scope means the provider
    # answers :github_not_connected, which must surface rather than crash.
    test "the repository step reaches GitHub and reports a missing connection", %{scope: scope} do
      assert {:halt, row, reason} = Provisioning.run_step(scope, :repository, owner: "someone")

      assert row.state == :errored
      assert reason =~ "GitHub" or reason =~ "github"
    end
  end
end
