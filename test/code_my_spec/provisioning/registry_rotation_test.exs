defmodule CodeMySpec.Provisioning.RegistryRotationTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.Registry

  import CodeMySpec.UsersFixtures

  test "replaces the stored secret and live htpasswd entry, then verifies auth and pull" do
    scope = full_scope_fixture()
    {:ok, old} = Registry.credential(scope)
    runner = runner(scope, old.password)

    assert :ok =
             Registry.rotate_credential(scope,
               run: runner,
               bind: "10.1.0.2",
               registry_attempts: 1
             )

    assert {:ok, current} = ProjectSecrets.fetch_value(scope, "registry_password")
    refute current == old.password

    assert_receive {:installed_hash, hash}
    assert Bcrypt.verify_pass(current, hash)
    refute Bcrypt.verify_pass(old.password, hash)
    assert_receive :old_rejected
    assert_receive :new_accepted
    assert_receive :docker_login_and_pull_verified
  end

  test "refuses to report success when the old credential still authenticates" do
    scope = full_scope_fixture()
    {:ok, old} = Registry.credential(scope)
    runner = runner(scope, old.password, old_accepted: true)

    assert {:error, :old_credential_still_accepted} =
             Registry.rotate_credential(scope,
               run: runner,
               bind: "10.1.0.2",
               registry_attempts: 1
             )

    refute_receive :docker_login_and_pull_verified
  end

  test "does not change the secret when the registry container is absent" do
    scope = full_scope_fixture()
    {:ok, old} = Registry.credential(scope)

    assert {:error, :registry_not_provisioned} =
             Registry.rotate_credential(scope, run: fn [_] -> {"", 0} end)

    assert {:ok, stored} = ProjectSecrets.fetch_value(scope, "registry_password")
    assert stored == old.password
  end

  test "does not return credential-bearing remote errors" do
    scope = full_scope_fixture()
    {:ok, old} = Registry.credential(scope)
    normal = runner(scope, old.password)

    leaking_runner = fn [command] = args ->
      leaking_command(String.contains?(command, "htpasswd.tmp"), args, old.password, normal)
    end

    result = Registry.rotate_credential(scope, run: leaking_runner)
    assert result == {:error, :rotation_failed}
    refute inspect(result) =~ old.password
    {:ok, current} = ProjectSecrets.fetch_value(scope, "registry_password")
    refute inspect(result) =~ current
  end

  defp runner(scope, old_password, opts \\ []) do
    context = %{scope: scope, old_password: old_password, opts: opts, owner: self()}
    fn [command] -> dispatch_command(command, context, command_flags(command)) end
  end

  defp leaking_command(true, _args, password, _normal), do: {password, 1}
  defp leaking_command(false, args, _password, normal), do: normal.(args)

  defp command_flags(command) do
    {String.starts_with?(command, "docker ps -q"), String.starts_with?(command, "docker port"),
     String.contains?(command, "htpasswd.tmp"), String.starts_with?(command, "curl"),
     String.starts_with?(command, "docker image ls"),
     String.contains?(command, "--password-stdin")}
  end

  defp dispatch_command(_command, _context, {true, _, _, _, _, _}),
    do: {"c0ffeec0ffee", 0}

  defp dispatch_command(_command, _context, {_, true, _, _, _, _}),
    do: {"10.1.0.2:5000\n", 0}

  defp dispatch_command(command, %{owner: owner}, {_, _, true, _, _, _}) do
    [_, hash] = Regex.run(~r/cms_[^:]+:(\$2b\$[^']+)/, command)
    send(owner, {:installed_hash, hash})
    {"", 0}
  end

  defp dispatch_command(command, context, {_, _, _, true, _, _}) do
    {:ok, current} = ProjectSecrets.fetch_value(context.scope, "registry_password")
    flags = {String.contains?(command, context.old_password), String.contains?(command, current)}
    auth_response(flags, context)
  end

  defp dispatch_command(_command, %{scope: scope}, {_, _, _, _, true, _}) do
    {:ok, image} = Registry.image(scope, registry_host: "10.1.0.2:5000")
    {image <> ":test-tag\n", 0}
  end

  defp dispatch_command(_command, %{owner: owner}, {_, _, _, _, _, true}) do
    send(owner, :docker_login_and_pull_verified)
    {"", 0}
  end

  defp dispatch_command(_command, _context, _flags), do: {"", 0}

  defp auth_response({true, _}, %{owner: owner, opts: opts}) do
    send(owner, :old_rejected)
    old_auth_status(Keyword.get(opts, :old_accepted, false))
  end

  defp auth_response({_, true}, %{owner: owner}) do
    send(owner, :new_accepted)
    {"", 0}
  end

  defp auth_response(_flags, _context), do: {"", 22}
  defp old_auth_status(true), do: {"", 0}
  defp old_auth_status(false), do: {"", 22}
end
