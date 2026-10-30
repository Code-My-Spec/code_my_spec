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
      if String.contains?(command, "htpasswd.tmp") do
        {old.password, 1}
      else
        normal.(args)
      end
    end

    result = Registry.rotate_credential(scope, run: leaking_runner)
    assert result == {:error, :rotation_failed}
    refute inspect(result) =~ old.password
    {:ok, current} = ProjectSecrets.fetch_value(scope, "registry_password")
    refute inspect(result) =~ current
  end

  defp runner(scope, old_password, opts \\ []) do
    owner = self()

    fn [command] ->
      cond do
        String.starts_with?(command, "docker ps -q") ->
          {"c0ffeec0ffee", 0}

        String.starts_with?(command, "docker port") ->
          {"10.1.0.2:5000\n", 0}

        String.contains?(command, "htpasswd.tmp") ->
          [_, hash] = Regex.run(~r/cms_[^:]+:(\$2b\$[^']+)/, command)
          send(owner, {:installed_hash, hash})
          {"", 0}

        String.starts_with?(command, "curl") ->
          {:ok, current} = ProjectSecrets.fetch_value(scope, "registry_password")

          cond do
            String.contains?(command, old_password) ->
              send(owner, :old_rejected)
              if Keyword.get(opts, :old_accepted, false), do: {"", 0}, else: {"", 22}

            String.contains?(command, current) ->
              send(owner, :new_accepted)
              {"", 0}

            true ->
              {"", 22}
          end

        String.starts_with?(command, "docker image ls") ->
          {:ok, image} = Registry.image(scope, registry_host: "10.1.0.2:5000")
          {image <> ":test-tag\n", 0}

        String.contains?(command, "--password-stdin") ->
          send(owner, :docker_login_and_pull_verified)
          {"", 0}

        true ->
          {"", 0}
      end
    end
  end
end
