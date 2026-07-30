defmodule CodeMySpec.ProjectSecretsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ProjectSecrets

  setup do
    %{scope: full_scope_fixture()}
  end

  describe "put_value/4 and fetch_value/3" do
    test "round-trips a value through encryption", %{scope: scope} do
      {:ok, _} = ProjectSecrets.put_value(scope, "HETZNER_S3_ACCESS_KEY", "AKIA-example")

      assert {:ok, "AKIA-example"} = ProjectSecrets.fetch_value(scope, "HETZNER_S3_ACCESS_KEY")
    end

    test "stores the value encrypted rather than as plaintext", %{scope: scope} do
      {:ok, _} = ProjectSecrets.put_value(scope, "AGE_PRIVATE_KEY", "AGE-SECRET-KEY-plaintext")

      # Read the raw column, bypassing the Ecto type, to prove the bytes on
      # disk are not the plaintext we handed in.
      {:ok, %{rows: [[raw]]}} =
        Repo.query("SELECT value FROM project_secrets WHERE key = $1", ["AGE_PRIVATE_KEY"])

      refute raw == "AGE-SECRET-KEY-plaintext"
      refute to_string(raw) =~ "AGE-SECRET-KEY-plaintext"
    end

    test "a missing key is not found", %{scope: scope} do
      assert {:error, :not_found} = ProjectSecrets.fetch_value(scope, "NOPE")
    end

    test "environments hold independent values for the same key", %{scope: scope} do
      {:ok, _} = ProjectSecrets.put_value(scope, "AGE_PRIVATE_KEY", "prod-key", environment: "prod")
      {:ok, _} = ProjectSecrets.put_value(scope, "AGE_PRIVATE_KEY", "uat-key", environment: "uat")

      assert {:ok, "prod-key"} =
               ProjectSecrets.fetch_value(scope, "AGE_PRIVATE_KEY", environment: "prod")

      assert {:ok, "uat-key"} =
               ProjectSecrets.fetch_value(scope, "AGE_PRIVATE_KEY", environment: "uat")
    end

    test "writing the same key twice converges instead of duplicating", %{scope: scope} do
      {:ok, _} = ProjectSecrets.put_value(scope, "CLOUDFLARE_TOKEN", "first")
      {:ok, _} = ProjectSecrets.put_value(scope, "CLOUDFLARE_TOKEN", "second")

      assert {:ok, "second"} = ProjectSecrets.fetch_value(scope, "CLOUDFLARE_TOKEN")
      assert [%{key: "CLOUDFLARE_TOKEN", environment: "global"}] = ProjectSecrets.list_keys(scope)
    end
  end

  describe "list_keys/1" do
    test "returns keys and environments but never values", %{scope: scope} do
      {:ok, _} = ProjectSecrets.put_value(scope, "A_KEY", "secret-a")

      [entry] = ProjectSecrets.list_keys(scope)

      assert entry == %{key: "A_KEY", environment: "global"}
      refute Map.has_key?(entry, :value)
    end
  end

  describe "project scoping" do
    test "one project cannot read another's secrets", %{scope: scope} do
      {:ok, _} = ProjectSecrets.put_value(scope, "SHARED_NAME", "project-one-value")

      other_scope = full_scope_fixture()

      assert {:error, :not_found} = ProjectSecrets.fetch_value(other_scope, "SHARED_NAME")
      assert ProjectSecrets.list_keys(other_scope) == []
    end
  end

  describe "has_value?/3" do
    test "answers without decrypting", %{scope: scope} do
      refute ProjectSecrets.has_value?(scope, "RESEND_API_KEY")

      {:ok, _} = ProjectSecrets.put_value(scope, "RESEND_API_KEY", "re_example")

      assert ProjectSecrets.has_value?(scope, "RESEND_API_KEY")
    end
  end

  describe "delete_value/3" do
    test "removes the secret", %{scope: scope} do
      {:ok, _} = ProjectSecrets.put_value(scope, "GONE_SOON", "value")
      {:ok, _} = ProjectSecrets.delete_value(scope, "GONE_SOON")

      assert {:error, :not_found} = ProjectSecrets.fetch_value(scope, "GONE_SOON")
    end

    test "deleting something absent is not found", %{scope: scope} do
      assert {:error, :not_found} = ProjectSecrets.delete_value(scope, "NEVER_EXISTED")
    end
  end
end
