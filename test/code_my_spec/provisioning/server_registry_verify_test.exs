defmodule CodeMySpec.Provisioning.ServerRegistryVerifyTest do
  @moduledoc """
  A box with no registry must not verify satisfied.

  c1d8eaff, reproduced without a real Hetzner project: `verify(:server, …)`
  used to be satisfied once every environment had a box **and**
  `DATABASE_URL` in its encrypted env — both cheap signals a stale box can
  carry. Neither says anything about the registry, which `run(:server, …)`
  is the only thing that ever starts (`serve_one_registry/5`). A box made by
  a run that errored before reaching that point, checked out fresh with an
  old `DATABASE_URL` still in the tree (exactly the report's repro: leftover
  `envs/*.enc.env` from a previous domain), verified satisfied, `run/3` was
  skipped, and the failure surfaced two steps later at `deploy` — a bare
  connection refused that never named the registry.

  Real sops and age, the way `secrets_verify_test.exs` does it: the claim
  under test is whether the step notices a real gap, which only the real
  tools can tell the truth about.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.{Environment, Local}
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{Hetzner, Sops, Steps}

  @moduletag :sops

  @server_name "some-name-uat"
  @network_id 42
  @public_ip "203.0.113.9"
  @private_ip "10.0.0.5"

  setup do
    scope = full_scope_fixture()
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_api_token", "test-token")

    stub_hetzner()

    {public, _private} = key_for(scope, "uat")
    :ok = Sops.write_config(scope.environment, %{"uat" => public})
    put_secret(scope, "uat", "DATABASE_URL", "postgresql://u:p@10.0.0.5:5432/app")
    put_secret(scope, "uat", "CMS_RESTORE_ADMIN_URL", "postgresql://u_restore:p@10.0.0.5:5432/postgres")

    {:ok, scope: scope}
  end

  # `:ssh_key_path` bypasses `write_builder_key/2` (and the real account
  # secret it reads), the same way an injected `:run` bypasses a real SSH
  # connection — neither claim under test is "can this process open an SSH
  # session", so neither needs to be real.
  defp verify_opts(run) do
    [environments: ["uat"], ssh_key_path: "unused", run: run]
  end

  describe "the box exists and DATABASE_URL is present, but the registry never came up" do
    test "verify(:server, …) reports absent, not satisfied", ctx do
      # What a curl against a registry nothing ever started actually returns:
      # `-sf` makes curl exit non-zero on a refused connection.
      run = fn [_command] -> {"", 7} end

      assert {:ok, :absent} = Steps.verify(:server, ctx.scope, verify_opts(run)),
             "a box with no registry must not read as done — the report's exact shape"
    end

    test "the registry is the only thing missing — everything else this step checks is already true",
         ctx do
      # Proven independently of the assertion above: without this fix, both
      # the box-listing check and the DATABASE_URL check the step already had
      # pass on their own, which is what made the bug reproduce as "satisfied"
      # rather than "absent for an obvious reason".
      assert {:ok, server} = Hetzner.find_server(ctx.scope, @server_name)
      assert get_in(server, ["public_net", "ipv4", "ip"]) == @public_ip

      {:ok, private} = ProjectSecrets.fetch_value(ctx.scope, "age_private_key_uat")

      assert {:ok, missing} =
               Sops.missing_secrets(ctx.scope.environment, "uat", private, ["DATABASE_URL"])

      assert "DATABASE_URL" not in missing
    end
  end

  describe "the box exists, DATABASE_URL is present, and the registry answers" do
    test "verify(:server, …) reports satisfied", ctx do
      run = fn [command] ->
        send(self(), {:ran, command})
        {"", 0}
      end

      assert {:ok, :satisfied, resources} = Steps.verify(:server, ctx.scope, verify_opts(run))

      assert Enum.any?(resources, &(&1.kind == "server"))

      assert_received {:ran, probe}
      assert probe =~ "curl"
      assert probe =~ "http://#{@private_ip}:5000/v2/"
    end
  end

  # A role provisioned before `CMS_RESTORE_ADMIN_URL` existed is otherwise
  # indistinguishable from one that has always had it: the box is there,
  # `DATABASE_URL` is there, the registry answers. Nothing about those three
  # checks changes when a role predates this credential. Reproduced without
  # a real Hetzner box, the same way the registry gap above is: strip just
  # this one secret back out and the rest of the setup still says "done" on
  # its own three checks, which is exactly the shape that let a box with no
  # registry read satisfied before c1d8eaff.
  describe "the box exists, DATABASE_URL is present, and the registry answers, but CMS_RESTORE_ADMIN_URL predates the fix" do
    setup ctx do
      # There is no `sops unset` — the whole file is re-initialised instead,
      # then given back only the one secret this describe block means to
      # still have present, reproducing a role provisioned back when
      # `CMS_RESTORE_ADMIN_URL` was never written at all.
      :ok = CodeMySpec.Environments.delete_file(ctx.scope.environment, Sops.env_file("uat"))
      put_secret(ctx.scope, "uat", "DATABASE_URL", "postgresql://u:p@10.0.0.5:5432/app")

      :ok
    end

    test "verify(:server, …) reports absent, not satisfied", ctx do
      run = fn [command] ->
        send(self(), {:ran, command})
        {"", 0}
      end

      assert {:ok, :absent} = Steps.verify(:server, ctx.scope, verify_opts(run)),
             "a role missing its restore credential must not read as done — the box, " <>
               "DATABASE_URL and the registry being fine says nothing about it"
    end
  end

  # Found live against MarketMySpec: a harness-scoped caller's scope carries
  # no working directory for a real project, and `Sops.missing_secrets/4`
  # resolves a relative path through it. `Environments.Local.resolve_path/2`
  # used to raise there rather than silently reading against the server's
  # own checkout — right instinct, wrong mechanism: the raise propagated out
  # of `verify(:server, …)` entirely, past `safe_verify/3`'s rescue, so the
  # step errored before `run_and_record/4` ever ran — nothing, not even the
  # database, was ever created, on a box whose only real problem was that
  # setup had never reached it yet. Fixed at `resolve_path/2` itself, which
  # now answers `{:error, :no_working_directory}` instead of raising, so
  # every caller's own already-correct "cannot prove it" handling runs
  # instead of being unwound past.
  #
  # The suite swaps `:local` for `RecordingEnvironment` globally
  # (`test_helper.exs`), which does not reproduce this — it always carries a
  # cwd, only the real `Environments.Local` needs to answer a directoryless
  # one. Restored to the real one for just this test, since the claim under
  # test is specifically about that module's own behavior.
  describe "the caller's scope carries no working directory" do
    test "verify(:server, …) reports absent instead of raising", ctx do
      previous = Application.get_env(:code_my_spec, :environment)
      Application.put_env(:code_my_spec, :environment, Local)

      on_exit(fn ->
        if previous do
          Application.put_env(:code_my_spec, :environment, previous)
        else
          Application.delete_env(:code_my_spec, :environment)
        end
      end)

      directoryless = %{ctx.scope | environment: Environment.new(:local, nil)}

      run = fn [_command] -> {"", 0} end

      assert {:ok, :absent} =
               Steps.verify(:server, directoryless, verify_opts(run)),
             "a scope with no working directory must not crash the check — " <>
               "absent is the honest answer, the same as any other unprovable claim"
    end

    # The write-side twin of the test above, and the one that actually
    # mattered live: `verify/3` raising only stopped the check from lying
    # about a resource that was never built. `put_secret/4` raising was
    # worse — it is on the *run* path, reached from `write_database_url/3`
    # inside `serve_one_registry/5`, and an uncaught raise there unwinds
    # straight past `serve_registries/5`'s own per-environment handling the
    # same way it unwinds past a `reduce_while`, landing in
    # `run_and_record/4`'s top-level rescue — which aborts the *whole*
    # :server step. Confirmed live against MarketMySpec: prod's write here
    # kept taking uat down with it even after `serve_registries/5` was
    # fixed to try every environment independently, because the failure
    # never reached that independence in the first place — it never
    # returned, it raised. Now that `resolve_path/2` itself answers cleanly,
    # this reaches `put_secret/4`'s own `with`/`else` like any other error.
    test "put_secret/4 reports a clean error instead of raising", ctx do
      previous = Application.get_env(:code_my_spec, :environment)
      Application.put_env(:code_my_spec, :environment, Local)

      on_exit(fn ->
        if previous do
          Application.put_env(:code_my_spec, :environment, previous)
        else
          Application.delete_env(:code_my_spec, :environment)
        end
      end)

      directoryless = %{ctx.scope | environment: Environment.new(:local, nil)}

      assert {:error, reason} =
               Steps.put_secret(directoryless, "prod", "DATABASE_URL", "ecto://u:p@host/db")

      assert reason =~ "working directory",
             "expected a clean, named reason rather than a raw exception message: #{reason}"
    end
  end

  defp key_for(scope, environment) do
    {:ok, {public, private}} = Sops.generate_key()
    {:ok, _} = ProjectSecrets.put_value(scope, "age_private_key_#{environment}", private)
    {public, private}
  end

  defp put_secret(scope, environment, key, value) do
    {:ok, private} = ProjectSecrets.fetch_value(scope, "age_private_key_#{environment}")
    :ok = Sops.put_secret(scope.environment, environment, key, value, private)
  end

  defp stub_hetzner do
    server = %{
      "id" => 1,
      "name" => @server_name,
      "location" => %{"name" => "fsn1"},
      "public_net" => %{"ipv4" => %{"ip" => @public_ip}},
      "private_net" => [%{"network" => @network_id, "ip" => @private_ip}]
    }

    network = %{"id" => @network_id, "name" => "some-name"}

    plug = fn conn -> reply(conn, conn.method, conn.request_path, server, network) end

    Req.Test.stub(Hetzner, plug)
  end

  defp reply(conn, "GET", "/v1/servers", server, _network),
    do: json(conn, %{"servers" => [server]})

  defp reply(conn, "GET", "/v1/networks", _server, network),
    do: json(conn, %{"networks" => [network]})

  defp reply(conn, "GET", "/v1/firewalls", _server, _network),
    do: json(conn, %{"firewalls" => []})

  defp reply(conn, "GET", "/v1/ssh_keys", _server, _network), do: json(conn, %{"ssh_keys" => []})

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
