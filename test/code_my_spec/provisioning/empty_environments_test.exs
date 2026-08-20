defmodule CodeMySpec.Provisioning.EmptyEnvironmentsTest do
  @moduledoc """
  A permitted-environments list of zero is not zero work remaining.

  `Enum.all?/2` over `[]` is `true`, and `Enum.reduce_while/3` over `[]` never
  enters its loop — so `verify(:secrets, …)` reported every one of zero
  environments' keys satisfied, and `run(:secrets, …)`, `run(:dns, …)` and
  `run(:deploy, …)` each reported success having minted no key, published no
  record, and shipped no release. `run(:server, …)` has its own regression
  test in `environment_servers_test.exs`, next to the Hetzner stub it needs.

  devops-drill (402f9439) is exactly this: a `prod` row from before `devops`
  was set to `:uat`, and no `uat` row was ever seeded to replace it —
  `EnvironmentRepository.list/1` only seeds when the existing row set is
  completely empty, so a project that already had one environment row never
  gets the other. `permitted_environment_rows/1` then filters `prod` out for
  `devops: :uat` and comes back with nothing, and every step below reported
  done against that nothing.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Projects
  alias CodeMySpec.Provisioning.{Cloudflare, EnvironmentRepository, Resend, Steps}

  setup do
    {:ok, scope: full_scope_fixture()}
  end

  describe "secrets" do
    test "verify does not report every key in an empty set satisfied", ctx do
      assert {:ok, :absent} = Steps.verify(:secrets, ctx.scope, environments: [])
    end

    test "run refuses instead of minting nothing and calling it done", ctx do
      assert {:error, reason} = Steps.run(:secrets, ctx.scope, environments: [])
      assert reason =~ "no environment is permitted"
    end
  end

  describe "deploy" do
    test "run refuses instead of shipping nothing and calling it done", ctx do
      # `environment: nil` short-circuits `deploy_ready/1` past the readiness
      # audit (357ce21a) — not a workaround, the same bypass that gate uses
      # for a scope with no checkout to read. What is under test here is
      # `deploy_environments/3`'s empty-list guard, which sits after it.
      scope = %{ctx.scope | environment: nil}

      assert {:error, reason} = Steps.run(:deploy, scope, environments: [])
      assert reason =~ "no environment is permitted"
    end
  end

  describe "dns" do
    setup ctx do
      {:ok, _} = Projects.update_project(ctx.scope, ctx.scope.active_project, %{domain: "astralbi.com"})

      Application.put_env(:code_my_spec, Cloudflare,
        api_token: "test-token",
        plug: fn conn -> zone_reply(conn, conn.request_path) end
      )

      on_exit(fn -> Application.delete_env(:code_my_spec, Cloudflare) end)

      %{scope: %{ctx.scope | active_project: %{ctx.scope.active_project | domain: "astralbi.com"}}}
    end

    # `prod` from before this project's devops level was set to `:uat`, and
    # never seeded a `uat` row to replace it — the exact shape of the
    # devops-drill row. `permitted_hosts/2` filters `prod` out and is left
    # with nothing to publish a record for.
    test "run refuses instead of publishing nothing and calling it done", ctx do
      {:ok, _} = EnvironmentRepository.put(ctx.scope, "prod", %{})
      {:ok, _} = Configurations.update(ctx.scope, %{devops: :uat})

      assert {:error, reason} = Steps.run(:dns, ctx.scope, [])
      assert reason =~ "no environment is permitted"
    end

    defp zone_reply(conn, "/client/v4/zones") do
      json(conn, [%{"id" => "z1", "name" => "astralbi.com"}])
    end

    defp zone_reply(conn, _path), do: json(conn, [])

    defp json(conn, result) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"success" => true, "errors" => [], "result" => result})
      )
    end
  end

  # 4dc83128: devops-drill's own shape — a `prod` row from before `devops` was
  # narrowed to `:uat`, no `uat` row seeded to replace it, and a real Resend
  # domain object left behind from before the narrowing. `mail_environments/2`
  # filters `prod` out either way; the difference under test is whether
  # something was ever actually registered at the provider.
  describe "email" do
    setup ctx do
      {:ok, _} = Projects.update_project(ctx.scope, ctx.scope.active_project, %{domain: "astralbi.com"})
      {:ok, _} = EnvironmentRepository.put(ctx.scope, "prod", %{})
      {:ok, _} = Configurations.update(ctx.scope, %{devops: :uat})

      %{scope: %{ctx.scope | active_project: %{ctx.scope.active_project | domain: "astralbi.com"}}}
    end

    test "verify reports satisfied when nothing was ever registered", ctx do
      stub_resend_domains(fn -> [] end)
      assert {:ok, :satisfied, []} = Steps.verify(:email, ctx.scope, [])
    end

    test "run stays a no-op when nothing was ever registered", ctx do
      stub_resend_domains(fn -> [] end)
      assert {:ok, []} = Steps.run(:email, ctx.scope, [])
    end

    test "verify does not report a stale registered domain satisfied", ctx do
      stub_resend_domains(fn -> [%{"id" => "d1", "name" => "astralbi.com", "status" => "failed"}] end)
      assert {:ok, :absent} = Steps.verify(:email, ctx.scope, [])
    end

    test "run pauses and names the orphan instead of calling it done", ctx do
      stub_resend_domains(fn -> [%{"id" => "d1", "name" => "astralbi.com", "status" => "failed"}] end)
      assert {:paused, reason} = Steps.run(:email, ctx.scope, [])
      assert reason =~ "astralbi.com"
      assert reason =~ "devops level"
    end

    defp stub_resend_domains(list_fun) do
      Application.put_env(:code_my_spec, Resend,
        api_key: "test-key",
        plug: fn conn -> resend_reply(conn, conn.request_path, list_fun.()) end
      )

      on_exit(fn -> Application.delete_env(:code_my_spec, Resend) end)
    end

    defp resend_reply(conn, "/domains", domains) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => domains}))
    end
  end
end
