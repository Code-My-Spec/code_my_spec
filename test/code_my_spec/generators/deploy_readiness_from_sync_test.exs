defmodule CodeMySpec.Generators.DeployReadinessFromSyncTest do
  @moduledoc """
  A harness-scoped caller's deploy-readiness check reads what the project's
  own file sync already knows, not just a live checkout it does not have.

  Found live against MarketMySpec: `run_provisioning_step(step: "deploy")`
  reported every boilerplate artifact missing — Dockerfile, .sops.yaml, both
  encrypted envs, bin/deploy, all of it — despite every one of them being
  real, committed, and pushed. `Generators.audit/2`'s existence checks only
  ever asked a directoryless environment, which can never answer honestly
  for a harness-scoped call. They did not need to ask that at all: this
  project's own file sync (`CodeMySpec.Files`) already had the answer,
  independent of any live checkout.

  Real DB access (`DataCase`), because the claim under test is specifically
  that `DeployBoilerplate.present?/2` falls back to a real `Files` row —
  nothing here is faked.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.{Environment, Local}
  alias CodeMySpec.Files
  alias CodeMySpec.Generators

  @router "lib/my_app_web/router.ex"

  setup do
    # The whole suite swaps `:environment` for `RecordingEnvironment`
    # (test_helper.exs), whose `file_exists?/2` resolves a nil cwd against
    # this very repo's own OS working directory rather than refusing —
    # so it answers "true" for paths this repo genuinely has (Dockerfile,
    # bin/deploy, ...), masking the exact incident this test proves. Swap
    # in the real adapter so a nil cwd behaves the way it does in
    # production: `false`, not "whatever happens to be underfoot".
    previous = Application.get_env(:code_my_spec, :environment)
    Application.put_env(:code_my_spec, :environment, Local)
    on_exit(fn -> Application.put_env(:code_my_spec, :environment, previous) end)
    :ok
  end

  defp directoryless_scope do
    scope = full_scope_fixture()
    %{scope | environment: Environment.new(:local, nil)}
  end

  defp sync(scope, path, role \\ :config) do
    {1, _} = Files.upsert_files(scope, [%{path: path, role: role}])
  end

  describe "a directoryless (harness-scoped) caller's audit" do
    test "reports nothing missing for artifacts the project's own sync already recorded" do
      scope = directoryless_scope()

      for path <- [
            "Dockerfile",
            ".github/workflows/build.yml",
            "config/deploy.yml",
            "config/deploy.uat.yml",
            ".sops.yaml",
            "rel/overlays/bin/boot",
            "rel/overlays/bin/migrate",
            "bin/deploy",
            "bin/backup",
            "envs/prod.enc.env",
            "envs/uat.enc.env"
          ] do
        sync(scope, path)
      end

      findings = Generators.audit(scope, @router)

      refute Enum.any?(findings, &match?({:missing_file, _}, &1)),
             "expected every synced artifact to read as present, got #{inspect(findings)}"

      refute Enum.any?(findings, &match?({:missing_env_file, _}, &1)),
             "expected both synced env files to read as present, got #{inspect(findings)}"
    end

    test "still reports an artifact as missing when sync never recorded it either" do
      scope = directoryless_scope()
      # Everything except the Dockerfile — the one thing genuinely absent.
      for path <- [
            ".github/workflows/build.yml",
            "config/deploy.yml",
            "config/deploy.uat.yml",
            ".sops.yaml",
            "rel/overlays/bin/boot",
            "rel/overlays/bin/migrate",
            "bin/deploy",
            "bin/backup"
          ] do
        sync(scope, path)
      end

      findings = Generators.audit(scope, @router)

      assert Enum.any?(findings, &match?({:missing_file, %{key: :dockerfile}}, &1)),
             "expected the genuinely-unsynced Dockerfile to still read as missing, got #{inspect(findings)}"
    end

    test "a plaintext env file the sync recorded is still flagged" do
      scope = directoryless_scope()
      sync(scope, ".env")

      assert {:plaintext_env_file, ".env"} in Generators.audit(scope, @router)
    end
  end
end
