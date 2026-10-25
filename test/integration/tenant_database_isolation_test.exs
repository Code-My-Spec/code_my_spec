defmodule CodeMySpec.TenantDatabaseIsolationTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Database
  alias CodeMySpec.Support.InMemoryExecutionContext
  alias CodeMySpec.Users.Scope
  alias CodeMySpecSpex.Fakes.Postgres

  setup do
    {:ok, env} = InMemoryExecutionContext.create()
    on_exit(fn -> InMemoryExecutionContext.destroy(env) end)
    %{env: env, run: fn [command] -> Postgres.run(env, command) end}
  end

  test "tenant setup refuses cross-tenant connections while preserving owner access", %{
    env: env,
    run: run
  } do
    seed(env)
    assert {"1", 0} = Postgres.connect(env, "app_alpha", "app_beta_prod")

    for tenant <- tenants() do
      assert {:ok, _} =
               Database.serve(%Scope{}, "prod",
                 run: run,
                 database_admin_credential: %{username: "postgres", password: "proof"},
                 database_credential: Map.put(tenant, :password, "proof"),
                 database_restore_credential: %{
                   username: tenant.username <> "_restore",
                   password: "restore"
                 }
               )
    end

    assert_isolated(env)
  end

  test "one-off repair isolates already provisioned databases and is repeatable", %{
    env: env,
    run: run
  } do
    seed(env)
    assert {"1", 0} = Postgres.connect(env, "app_alpha", "app_beta_prod")
    opts = [run: run, database_admin_credential: %{username: "postgres", password: "proof"}]
    assert {:ok, ["app_alpha_prod", "app_beta_prod"]} = Database.repair_existing(%Scope{}, opts)
    assert_isolated(env)
    assert {:ok, ["app_alpha_prod", "app_beta_prod"]} = Database.repair_existing(%Scope{}, opts)
    assert_isolated(env)
  end

  defp tenants,
    do: [
      %{username: "app_alpha", database: "app_alpha_prod"},
      %{username: "app_beta", database: "app_beta_prod"}
    ]

  defp seed(env) do
    for tenant <- tenants(), do: Postgres.seed(env, tenant.database, tenant.username)
  end

  defp assert_isolated(env) do
    assert {"1", 0} = Postgres.connect(env, "app_alpha", "app_alpha_prod")
    assert {"1", 0} = Postgres.connect(env, "app_beta", "app_beta_prod")

    assert {"permission denied for database app_beta_prod", 2} =
             Postgres.connect(env, "app_alpha", "app_beta_prod")

    assert {"permission denied for database app_alpha_prod", 2} =
             Postgres.connect(env, "app_beta", "app_alpha_prod")
  end
end
