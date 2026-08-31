defmodule CodeMySpec.Provisioning.CheckSecretsFromFilesTableTest do
  @moduledoc """
  Whether `check_secrets/2` trusts the harness's own report instead of trying
  to read a harness-only project's encrypted env file directly.

  Reported live against MarketMySpec: `check_secrets/2` read
  `envs/prod.enc.env` via `Environments.file_exists?/2` against
  `scope.environment` — unreachable for a project connected only through a
  harness (it resolves to `Environment.new(:local, project.local_path)`,
  `local_path: nil`) — so it reported every required secret missing
  regardless of what the file actually contained.
  `Scanner.validate_entry/4`'s `:encrypted_env` clause now checks this at
  sync time, where the file really is; this proves `check_secrets/2` trusts
  that verdict instead, with no reachable environment at check time at all.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{Sops, Steps}

  setup do
    scope = full_scope_fixture()
    {:ok, {_public, private}} = Sops.generate_key()
    {:ok, _} = ProjectSecrets.put_value(scope, "age_private_key_prod", private)
    %{scope: scope}
  end

  # An environment that resolves but cannot actually be read from — the same
  # shape a harness-only project's `Environment.new(:local, project.
  # local_path)` takes when `local_path` is nil. Distinct from `nil` itself,
  # which is a different, earlier-guarded failure (`no_environment_message/0`).
  defp unreachable(scope), do: %{scope | environment: Environment.new(:local, nil)}

  defp sync_env_file(scope, content) do
    {:ok, tmp} = Briefly.create(directory: true)
    env = Environment.new(:local, tmp)
    Environments.write_file(env, "envs/prod.enc.env", content)
    {:ok, _} = FileSync.sync(%{scope | environment: env}, base_dir: tmp)
    :ok
  end

  describe "the harness has reported a verdict" do
    test "both required secrets present succeeds with no reachable environment", %{
      scope: scope
    } do
      :ok =
        sync_env_file(scope, """
        SECRET_KEY_BASE=ENC[AES256_GCM,data:aaaa,iv:bbbb,tag:cccc,type:str]
        DATABASE_URL=ENC[AES256_GCM,data:dddd,iv:eeee,tag:ffff,type:str]
        """)

      assert {:ok, _delivery} = Steps.check_secrets(unreachable(scope), "prod")
    end

    test "a missing secret is refused by name, from the report alone", %{scope: scope} do
      :ok =
        sync_env_file(scope, """
        SECRET_KEY_BASE=ENC[AES256_GCM,data:aaaa,iv:bbbb,tag:cccc,type:str]
        """)

      assert {:error, message} = Steps.check_secrets(unreachable(scope), "prod")
      assert message =~ "DATABASE_URL"
      refute message =~ "SECRET_KEY_BASE"
    end
  end

  describe "nothing has been reported yet" do
    test "an unreachable environment with no synced file reports everything missing", %{
      scope: scope
    } do
      assert {:error, message} = Steps.check_secrets(unreachable(scope), "prod")
      assert message =~ "SECRET_KEY_BASE"
      assert message =~ "DATABASE_URL"
    end
  end
end
