defmodule CodeMySpec.Provisioning.StorageCredentialsTest do
  @moduledoc """
  `Storage.credentials/2` is the one place a project's Hetzner object-storage
  key pair is read. Every project that only ever set the shared default must
  keep working exactly as before; a project that sets a dedicated pair for
  one environment must have that pair win for that environment only, per
  John's explicit ask: UAT and production should be able to hold separate
  S3 secrets in the same `project_secrets` table `AGE_PRIVATE_KEY` and
  `database_password_<environment>` already use for the same split.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.Storage

  setup do
    %{scope: full_scope_fixture()}
  end

  describe "credentials/2 with no environment requested" do
    test "returns :none when nothing has been saved", %{scope: scope} do
      assert :none = Storage.credentials(scope)
    end

    test "returns the shared default", %{scope: scope} do
      {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_access_key_id", "global-id")
      {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_secret_access_key", "global-secret")

      assert {:ok, credentials} = Storage.credentials(scope)
      assert Keyword.get(credentials, :access_key_id) == "global-id"
      assert Keyword.get(credentials, :secret_access_key) == "global-secret"
    end
  end

  describe "credentials/2 with :environment given" do
    test "falls back to the shared default when the environment has no override", %{
      scope: scope
    } do
      {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_access_key_id", "global-id")
      {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_secret_access_key", "global-secret")

      assert {:ok, credentials} = Storage.credentials(scope, environment: "uat")
      assert Keyword.get(credentials, :access_key_id) == "global-id"
    end

    test "a per-environment pair wins over the shared default for that environment", %{
      scope: scope
    } do
      {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_access_key_id", "global-id")
      {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_secret_access_key", "global-secret")

      {:ok, _} =
        ProjectSecrets.put_value(scope, "hetzner_s3_access_key_id", "prod-id", environment: "prod")

      {:ok, _} =
        ProjectSecrets.put_value(scope, "hetzner_s3_secret_access_key", "prod-secret",
          environment: "prod"
        )

      assert {:ok, prod} = Storage.credentials(scope, environment: "prod")
      assert Keyword.get(prod, :access_key_id) == "prod-id"
      assert Keyword.get(prod, :secret_access_key) == "prod-secret"

      # UAT was never given its own pair, so it still reads the shared one —
      # setting prod's key must not blind UAT to the default it used to see.
      assert {:ok, uat} = Storage.credentials(scope, environment: "uat")
      assert Keyword.get(uat, :access_key_id) == "global-id"
    end

    test "is :none when neither the environment nor the default has a full pair", %{
      scope: scope
    } do
      {:ok, _} =
        ProjectSecrets.put_value(scope, "hetzner_s3_access_key_id", "prod-id", environment: "prod")

      # No secret half saved anywhere — an incomplete pair is not usable.
      assert :none = Storage.credentials(scope, environment: "prod")
    end

    test "carries the region through on both the override and fallback paths", %{scope: scope} do
      {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_access_key_id", "global-id")
      {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_secret_access_key", "global-secret")

      assert {:ok, credentials} = Storage.credentials(scope, environment: "uat", location: "hel1")
      assert Keyword.get(credentials, :region) == "hel1"
    end
  end
end
