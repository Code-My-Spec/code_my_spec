defmodule CodeMySpec.Provisioning.QaFixtureTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.QaFixture
  alias CodeMySpec.ProvisioningPlan.StepRepository

  setup do
    scope = full_scope_fixture()
    :ok = QaFixture.register(scope.active_project_id, scope.active_account_id)
    %{scope: scope}
  end

  test "a retry converges and a deleted provider resource is rebuilt", %{scope: scope} do
    assert {:ok, first} = Provisioning.run_step(scope, :server, nil, [])
    assert first.state == :done
    assert {:ok, second} = Provisioning.run_step(scope, :server, nil, [])
    assert second.resources == first.resources
    assert {:ok, before} = QaFixture.snapshot(scope.active_project_id)
    assert length(before.resources) == 1
    assert Enum.count(before.events, &(&1.operation == "execute")) == 1

    assert :ok = QaFixture.control(scope.active_project_id, "server", "delete")
    assert StepRepository.get(scope, :server).state == :done
    assert {:ok, rebuilt} = Provisioning.run_step(scope, :server, nil, [])
    assert rebuilt.state == :done
    assert [historical] = Enum.reject(rebuilt.resources, & &1.observed_in_latest_run)
    assert historical.identifier == hd(first.resources).identifier
    assert [current] = Enum.filter(rebuilt.resources, & &1.observed_in_latest_run)
    refute current.identifier == historical.identifier
    assert StepRepository.get(scope, :server).resources == rebuilt.resources
    assert {:ok, after_rebuild} = QaFixture.snapshot(scope.active_project_id)
    assert length(after_rebuild.resources) == 1
    refute hd(after_rebuild.resources).identifier == hd(before.resources).identifier
    assert Enum.count(after_rebuild.events, &(&1.operation == "execute")) == 2
  end

  test "domain stays paused until the external fixture action", %{scope: scope} do
    assert {:halt, first, _} = Provisioning.run_step(scope, :domain, nil, [])
    assert first.state == :paused
    assert {:halt, second, _} = Provisioning.run_step(scope, :domain, nil, [])
    assert second.state == :paused
    assert second.paused_instructions == first.paused_instructions
    assert :ok = QaFixture.control(scope.active_project_id, "domain", "register")
    assert {:ok, completed} = Provisioning.run_step(scope, :domain, nil, [])
    assert completed.state == :done
  end

  test "provider refusal is recorded verbatim and retry leaves other steps alone", %{scope: scope} do
    assert {:ok, domain} = Provisioning.run_step(scope, :secrets, "prod", [])
    assert :ok = QaFixture.control(scope.active_project_id, "email", "refuse")
    assert {:halt, failed, reason} = Provisioning.run_step(scope, :email, nil, [])
    assert reason == "QA provider refused: token lacks permission to create this resource"
    assert Provisioning.escalation(failed).provider_error == reason
    assert :ok = QaFixture.control(scope.active_project_id, "email", "allow")
    assert {:ok, recovered} = Provisioning.run_step(scope, :email, nil, [])
    assert recovered.state == :done
    assert StepRepository.get(scope, :secrets, "prod") == domain
  end

  test "a held step broadcasts running and completes after release", %{scope: scope} do
    assert :ok = Provisioning.subscribe(scope)
    assert :ok = QaFixture.control(scope.active_project_id, "server", "hold")
    task = Task.async(fn -> Provisioning.run_step(scope, :server, nil, []) end)
    assert_receive {:provisioning, :step, %{key: :server, state: :running}}, 5_000
    assert StepRepository.get(scope, :server).state == :running
    assert :ok = QaFixture.control(scope.active_project_id, "server", "release")
    assert {:ok, %{state: :done}} = Task.await(task, 5_000)
    assert_receive {:provisioning, :step, %{key: :server, state: :done}}, 5_000
  end

  test "an expired fixture cannot invoke real providers", %{scope: scope} do
    project = %{
      scope.active_project
      | description: "QA provisioning simulator; requires an active development fixture."
    }

    expired = %{scope | active_project: project, active_project_id: Ecto.UUID.generate()}
    opts = QaFixture.options(expired, [])
    expected = {:error, "QA provider fixture is unavailable; create a fresh development fixture."}
    assert opts[:verify].(expired, :server) == expected
    assert opts[:execute].(expired, :server, []) == expected
  end

  test "satisfied checks persist and broadcast their time without graph invalidation", %{
    scope: scope
  } do
    assert {:ok, _} = Provisioning.run_step(scope, :server, nil, [])
    assert {:ok, _} = Provisioning.run_step(scope, :storage, "prod", [])
    :ok = Provisioning.subscribe(scope)
    before_count = length(CodeMySpec.Requirements.Invalidations.pending(scope.active_project_id))
    before_check = DateTime.utc_now()

    assert {:ok, server} = Provisioning.run_step(scope, :server, nil, [])
    assert {:ok, storage} = Provisioning.run_step(scope, :storage, "prod", [])

    assert DateTime.compare(server.verified_at, before_check) in [:eq, :gt]
    assert DateTime.compare(storage.verified_at, before_check) in [:eq, :gt]
    assert StepRepository.get(scope, :server).verified_at == server.verified_at
    assert StepRepository.get(scope, :storage, "prod").verified_at == storage.verified_at
    assert_receive {:provisioning, :step, ^server}
    assert_receive {:provisioning, :step, ^storage}

    assert length(CodeMySpec.Requirements.Invalidations.pending(scope.active_project_id)) ==
             before_count
  end

  test "environment resources and verification remain separate", %{scope: scope} do
    assert {:ok, prod} = Provisioning.run_step(scope, :storage, "prod", [])
    assert {:ok, uat} = Provisioning.run_step(scope, :storage, "uat", [])
    refute prod.resources == uat.resources

    assert {:ok, :satisfied, resources} =
             Provisioning.verify(scope, :storage, environment: "prod")

    assert hd(resources).identifier == hd(prod.resources).identifier
    assert {:ok, snapshot} = QaFixture.snapshot(scope.active_project_id)
    assert length(snapshot.resources) == 2
  end

  test "ordinary projects and other accounts retain their exact options", %{scope: scope} do
    opts = [environment: "prod", force: true]
    other_project = %{scope | active_project_id: Ecto.UUID.generate()}
    other_account = %{scope | active_account_id: Ecto.UUID.generate()}
    assert QaFixture.options(other_project, opts) == opts
    assert QaFixture.options(other_account, opts) == opts

    assert QaFixture.control(other_project.active_project_id, "server", "delete") ==
             {:error, :not_registered}

    assert QaFixture.control(scope.active_project_id, "unknown", "delete") ==
             {:error, :invalid_control}
  end
end
