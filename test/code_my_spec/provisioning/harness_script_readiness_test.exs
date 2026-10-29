defmodule CodeMySpec.Provisioning.HarnessScriptReadinessTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Generators
  alias CodeMySpec.Generators.DeployBoilerplate
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.Steps

  defmodule HarnessFiles do
    @behaviour CodeMySpec.ExecutionContexts.HarnessTransport

    @impl true
    def harness_fs_request(_id, "stat", %{"path" => path}, _timeout) do
      if String.starts_with?(path, ".env"), do: {:error, :enoent}, else: {:ok, %{"size" => 0}}
    end

    def harness_fs_request(_id, _op, _payload, _timeout), do: {:error, :harness_unreachable}
  end

  setup do
    scope = provisioning_scope_fixture(%{module_name: "Example", health_route_status: "ok"})
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_access_key_id", "key")
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_secret_access_key", "secret")
    %{scope: scope}
  end

  test "a harness file with a clean audit passes the backup script guard", %{scope: scope} do
    tmp = CodeMySpec.TempFile.owned_dir("harness_script_readiness")
    File.mkdir_p!(Path.join(tmp, "bin"))
    File.write!(Path.join(tmp, "bin/backup"), "#!/bin/sh\n")

    {:ok, _} =
      FileSync.sync(scope, base_dir: tmp, execution_context: ExecutionContext.new(:local, tmp))

    assert Files.get_by_path(scope, "bin/backup")

    previous = Application.get_env(:code_my_spec, :harness_fs_transport)
    Application.put_env(:code_my_spec, :harness_fs_transport, HarnessFiles)

    on_exit(fn ->
      if previous do
        Application.put_env(:code_my_spec, :harness_fs_transport, previous)
      else
        Application.delete_env(:code_my_spec, :harness_fs_transport)
      end
    end)

    harness = ExecutionContext.new(:harness, nil, ref: %{"harness_id" => Ecto.UUID.generate()})
    :ok = ExecutionContexts.unregister({:working_copy, scope.active_working_copy_id})
    :ok = ExecutionContexts.register({:working_copy, scope.active_working_copy_id}, harness)
    assert Generators.audit(scope, "lib/example_web/router.ex", harness) == []
    refute ExecutionContexts.exec_file_exists?(harness, "bin/backup")
    assert ExecutionContexts.file_exists?(harness, "bin/backup")

    assert {:error, reason, []} = Steps.run(:backups, scope, environments: ["uat"])
    refute reason =~ "bin/backup is not present or not executable"
  end

  test "a local script without execute permission is still refused", %{scope: scope} do
    tmp = CodeMySpec.TempFile.owned_dir("local_script_readiness")
    env = ExecutionContext.new(:local, tmp)
    scope = put_fixture_execution_context(scope, env)

    for path <-
          Enum.map(DeployBoilerplate.manifest(), & &1.path) ++
            ["envs/prod.enc.env", "envs/uat.enc.env", "lib/example/release.ex"] do
      full = Path.join(tmp, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, "fixture\n")
    end

    File.chmod!(Path.join(tmp, "bin/backup"), 0o644)
    assert Generators.audit(scope, "lib/example_web/router.ex", env) == []
    assert ExecutionContexts.file_exists?(env, "bin/backup")
    {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(tmp, "bin/backup"))
    assert Bitwise.band(mode, 0o111) == 0

    assert {:error, reason, []} = Steps.run(:backups, scope, environments: ["uat"])
    assert reason =~ "bin/backup is not present or not executable"
  end
end
