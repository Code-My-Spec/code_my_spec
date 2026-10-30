defmodule CodeMySpec.Provisioning.DeployImportReadinessTest do
  @moduledoc """
  Issue b6daceee: deploy targeted an empty database because nothing checked
  whether an adopting project's target already held its legacy data. This
  guard sits right behind `check_secrets`, same as the config-target guard
  (`DeployConfigTargetTest`), and for the same reason — a project whose
  environment never named a legacy source must never reach it at all.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Generators.DeployArtifacts
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Environments
  alias CodeMySpec.Provisioning.{Sops, Steps}

  @domain "import-readiness.example.com"

  @moduletag :sops

  # Mirrors `DeployConfigTargetTest`'s setup: the guard under test sits
  # behind both `deploy_ready`'s audit and `check_secrets`, so a fixture
  # missing either never reaches it.
  setup do
    Sops.available?() ||
      raise """
      sops and age are not installed, and this test is meaningless without
      them — the guard under test sits behind `check_secrets`, so it would
      pass having never reached it.
      """

    tmp = CodeMySpec.TempFile.owned_dir("deploy_import_readiness")

    scope =
      put_fixture_execution_context(
        provisioning_scope_fixture(),
        ExecutionContext.new(:local, tmp)
      )

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{domain: @domain})

    scope = %{scope | active_project: project}

    {:ok, {public, private}} = Sops.generate_key()
    ProjectSecrets.put_value(scope, "age_private_key_uat", private)

    env = fixture_execution_context(scope)
    :ok = Sops.write_config(env, %{"uat" => public})
    :ok = Sops.put_secret(env, "uat", "SECRET_KEY_BASE", "x", private)
    :ok = Sops.put_secret(env, "uat", "DATABASE_URL", "ecto://x", private)

    File.mkdir_p!(Path.join(tmp, "config"))
    write_boilerplate(tmp)
    write_config(tmp, @domain)

    {:ok, _} =
      Environments.put(scope, "uat", %{
        import_source_container: "legacy-pg",
        import_source_database: "legacy_db"
      })

    {:ok, scope: scope}
  end

  @generated_by_setup ["config/deploy.uat.yml", ".sops.yaml", "envs/uat.enc.env"]

  defp write_boilerplate(tmp) do
    for {path, body} <-
          DeployArtifacts.files(app: "my_app", host: @domain, registry: "ghcr.io", owner: "acme"),
        path not in @generated_by_setup do
      full = Path.join(tmp, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end
  end

  defp write_config(tmp, host) do
    File.write!(Path.join(tmp, "config/deploy.uat.yml"), """
    service: import-readiness-uat
    servers:
      web:
        - #{host}
    proxy:
      ssl: true
      host: #{host}
    """)
  end

  defp counting_run(source_count, target_count) do
    fn [command] ->
      row_count_response(
        String.contains?(command, "json_object_agg"),
        String.contains?(command, "'legacy-pg'"),
        source_count,
        target_count
      )
    end
  end

  defp row_count_response(false, _from_source?, _source_count, _target_count), do: {"", 0}

  defp row_count_response(true, true, source_count, _target_count),
    do: {Jason.encode!(%{"t" => source_count}), 0}

  defp row_count_response(true, false, _source_count, target_count),
    do: {Jason.encode!(%{"t" => target_count}), 0}

  describe "a target database still behind its source" do
    test "refuses the deploy by name, before anything is built", ctx do
      assert {:error, message} =
               Steps.run(:deploy, ctx.scope, environment: "uat", run: counting_run(3, 0))

      assert message =~ "uat"
      assert message =~ "legacy-pg/legacy_db"
      assert message =~ "empty database"
    end
  end

  describe "a target database that already matches its source" do
    test "does not refuse on the import check — whatever it fails on next is unrelated", ctx do
      assert {:error, message} =
               Steps.run(:deploy, ctx.scope, environment: "uat", run: counting_run(3, 3))

      refute message =~ "empty database"
    end
  end

  describe "an environment that never named a legacy source" do
    test "never asks the box at all", ctx do
      {:ok, _} =
        Environments.put(ctx.scope, "uat", %{
          import_source_container: nil,
          import_source_database: nil
        })

      run = fn _ -> flunk("a project with nothing to import must never reach the box") end

      assert {:error, message} = Steps.run(:deploy, ctx.scope, environment: "uat", run: run)
      refute message =~ "empty database"
    end
  end
end
