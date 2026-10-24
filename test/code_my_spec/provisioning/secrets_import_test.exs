defmodule CodeMySpec.Provisioning.SecretsImportTest do
  @moduledoc """
  Issue a634ffac / story 967: an app that already has its own secrets gets
  them imported and kept, not replaced by a fresh mint -- SECRET_KEY_BASE
  included, so a live app's sessions stay valid across adoption.

  Real sops and age throughout, same as `SecretsVerifyTest` and `SopsTest`
  -- the claim is about the real encrypted file, not a model of it.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{Sops, Steps}

  @moduletag :sops

  # No check that sops is installed: `test_helper.exs` excludes `:sops`
  # entirely on a machine without the binaries, so reaching here means they
  # are there.
  setup do
    tmp = CodeMySpec.TempFile.owned_dir("test")

    scope =
      put_fixture_execution_context(
        provisioning_scope_fixture(),
        ExecutionContext.new(:local, tmp)
      )

    {:ok, scope: scope, tmp: tmp}
  end

  defp decrypted(scope, environment) do
    {:ok, private} = ProjectSecrets.fetch_value(scope, Steps.age_key_name(environment))
    Sops.decrypt(fixture_execution_context(scope), environment, private)
  end

  describe "import_dotenv/3" do
    test "writes every KEY=value line as a real secret, skipping comments and blanks", ctx do
      dotenv = """
      # existing production env, copied by hand
      SECRET_KEY_BASE=test-existing-secret-key-base

      OTHER_KEY=test-other-value
      """

      assert {:ok, keys} = Steps.import_dotenv(ctx.scope, "prod", dotenv)
      assert Enum.sort(keys) == ["OTHER_KEY", "SECRET_KEY_BASE"]

      assert {:ok, decrypted} = decrypted(ctx.scope, "prod")
      assert decrypted["SECRET_KEY_BASE"] == "test-existing-secret-key-base"
      assert decrypted["OTHER_KEY"] == "test-other-value"
    end

    test "a line with no '=' is skipped rather than written as a secret", ctx do
      assert {:ok, []} = Steps.import_dotenv(ctx.scope, "prod", "not a dotenv line at all")
    end
  end

  describe "the secrets step, once an app's own secrets are imported" do
    test "keeps the imported SECRET_KEY_BASE instead of minting a replacement", ctx do
      dotenv = "SECRET_KEY_BASE=test-existing-secret-key-base\n"
      assert {:ok, ["SECRET_KEY_BASE"]} = Steps.import_dotenv(ctx.scope, "prod", dotenv)

      assert {:ok, _minted} = Steps.run(:secrets, ctx.scope, environments: ["prod"])

      assert {:ok, decrypted} = decrypted(ctx.scope, "prod")
      assert decrypted["SECRET_KEY_BASE"] == "test-existing-secret-key-base"
    end

    test "still mints SECRET_KEY_BASE when nothing was imported first", ctx do
      assert {:ok, minted} = Steps.run(:secrets, ctx.scope, environments: ["prod"])

      assert Enum.any?(minted, &(&1.location == "prod/SECRET_KEY_BASE"))

      assert {:ok, decrypted} = decrypted(ctx.scope, "prod")
      assert is_binary(decrypted["SECRET_KEY_BASE"])
      refute decrypted["SECRET_KEY_BASE"] == "test-existing-secret-key-base"
    end
  end
end
