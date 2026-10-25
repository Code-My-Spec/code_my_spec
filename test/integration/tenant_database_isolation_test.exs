defmodule CodeMySpec.TenantDatabaseIsolationTest do
  use ExUnit.Case, async: false

  alias CodeMySpec.Provisioning.Database
  alias CodeMySpec.Users.Scope

  @moduletag :docker
  @moduletag timeout: 120_000

  setup do
    name = "cms-isolation-#{System.unique_integer([:positive])}"
    on_exit(fn -> System.cmd("docker", ["rm", "-f", name], stderr_to_stdout: true) end)

    {_, 0} =
      System.cmd(
        "docker",
        ["run", "-d", "--name", name, "-e", "POSTGRES_PASSWORD=proof", "pgvector/pgvector:pg18"],
        stderr_to_stdout: true
      )

    ready(name, 60)

    run = fn [command] ->
      command = String.replace(command, "cms-postgres", name)
      System.cmd("sh", ["-c", command], stderr_to_stdout: true)
    end

    %{container: name, run: run}
  end

  test "fresh tenants and repaired legacy tenants refuse each other's connections", %{
    container: name,
    run: run
  } do
    scope = %Scope{}
    alpha = %{username: "app_alpha", password: "alpha", database: "app_alpha_prod"}
    beta = %{username: "app_beta", password: "beta", database: "app_beta_prod"}

    for tenant <- [alpha, beta] do
      assert {:ok, _} =
               Database.serve(scope, "prod",
                 run: run,
                 database_admin_credential: %{username: "postgres", password: "proof"},
                 database_credential: tenant,
                 database_restore_credential: %{
                   username: tenant.username <> "_restore",
                   password: "restore"
                 }
               )
    end

    assert_access(name, alpha, beta)
    assert_access(name, beta, alpha)

    {_, 0} =
      sql(
        name,
        "GRANT CONNECT ON DATABASE app_alpha_prod TO PUBLIC; GRANT CONNECT ON DATABASE app_beta_prod TO PUBLIC;"
      )

    assert {_, 0} = connect(name, alpha, beta.database)
    opts = [run: run, database_admin_credential: %{username: "postgres", password: "proof"}]
    assert {:ok, ["app_alpha_prod", "app_beta_prod"]} = Database.repair_existing(scope, opts)
    assert {:ok, ["app_alpha_prod", "app_beta_prod"]} = Database.repair_existing(scope, opts)
    assert_access(name, alpha, beta)
    assert_access(name, beta, alpha)
  end

  defp assert_access(name, tenant, other) do
    assert {_, 0} = connect(name, tenant, tenant.database)
    {message, status} = connect(name, tenant, other.database)
    assert status == 2
    assert message =~ "permission denied for database"
  end

  defp connect(name, tenant, database) do
    System.cmd(
      "docker",
      [
        "exec",
        "-e",
        "PGPASSWORD=#{tenant.password}",
        name,
        "psql",
        "-h",
        "127.0.0.1",
        "-U",
        tenant.username,
        "-d",
        database,
        "-c",
        "SELECT 1"
      ],
      stderr_to_stdout: true
    )
  end

  defp sql(name, sql) do
    System.cmd(
      "docker",
      [
        "exec",
        name,
        "psql",
        "-v",
        "ON_ERROR_STOP=1",
        "-U",
        "postgres",
        "-d",
        "postgres",
        "-c",
        sql
      ],
      stderr_to_stdout: true
    )
  end

  defp ready(name, attempts) do
    case System.cmd("docker", ["exec", name, "pg_isready", "-h", "127.0.0.1"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      _ when attempts > 1 ->
        Process.sleep(1_000)
        ready(name, attempts - 1)

      result ->
        flunk("Postgres did not become ready: #{inspect(result)}")
    end
  end
end
