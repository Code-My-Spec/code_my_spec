defmodule CodeMySpec.TelemetryTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ProjectsFixtures
  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias CodeMySpec.Telemetry
  alias CodeMySpec.UsersFixtures

  setup do
    user = UsersFixtures.user_fixture()
    scope = UsersFixtures.user_scope_fixture(user)
    project = ProjectsFixtures.project_fixture(scope)

    {:ok, scope: %{scope | active_project_id: project.id, active_project: project}}
  end

  describe "run/3" do
    test "requires the environment's server to exist first", %{scope: scope} do
      assert {:error, reason} = Telemetry.run(scope, "uat")
      assert reason =~ "server"
    end

    test "proves the collector and returns its resources once the server exists", %{
      scope: scope
    } do
      EnvironmentRepository.put(scope, "uat", %{ip: "203.0.113.10"})

      probe = fn _opts -> {:ok, %{logs: 1, traces: 1}} end

      assert {:ok, resources} = Telemetry.run(scope, "uat", run_probe: probe)
      assert Enum.any?(resources, &(&1.kind == "telemetry_collector"))

      assert Enum.any?(
               resources,
               &(&1.kind == "telemetry_retention" and &1.identifier == "14")
             )
    end

    test "surfaces the probe's own error", %{scope: scope} do
      EnvironmentRepository.put(scope, "uat", %{ip: "203.0.113.10"})

      probe = fn _opts -> {:error, "the collector is not running"} end

      assert {:error, "the collector is not running"} =
               Telemetry.run(scope, "uat", run_probe: probe)
    end
  end

  describe "check/3" do
    test "reports the injected probe's reachability, reads and writes", %{scope: scope} do
      probe = fn _opts -> %{reachable: true, reads: :ok, writes: :refused} end

      result = Telemetry.check(scope, "uat", check_probe: probe)

      assert result.reachable
      assert result.reads == :ok
      assert result.writes == :refused
      assert %DateTime{} = result.checked_at
    end
  end

  describe "query/3" do
    test "scopes the query to the calling project", %{scope: scope} do
      probe = fn opts -> {:ok, %{project_id: Keyword.fetch!(opts, :project_id)}} end

      assert {:ok, %{project_id: project_id}} =
               Telemetry.query(scope, "uat", query_probe: probe)

      assert project_id == scope.active_project_id
    end

    test "defaults since_days to the retention window", %{scope: scope} do
      probe = fn opts -> {:ok, %{since_days: Keyword.fetch!(opts, :since_days)}} end

      assert {:ok, %{since_days: 14}} = Telemetry.query(scope, "uat", query_probe: probe)
    end
  end

  describe "retention_days/0" do
    test "is 14 days" do
      assert Telemetry.retention_days() == 14
    end
  end
end
