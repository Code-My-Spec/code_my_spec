defmodule CodeMySpec.Provisioning.DeployConfigTargetTest do
  @moduledoc """
  Whether the deploy step checks that the kamal config points at this
  project's server before it deploys.

  Where a deploy lands is decided by `config/deploy.<env>.yml` in the
  checkout. Nothing setup passes kamal changes that — the `:host` the step
  computes is only the health probe's target. So a config naming another
  machine deployed this project's image onto that machine and then reported a
  health failure against a hostname it had never touched: the wrong server
  changed, and the error pointed elsewhere.

  A drill seeded from another app found it, with `proxy.host: uat.astralbi.com`
  still in place while the project's own uat was `uat.drill.astralbi.com`.
  That stale file was the drill's doing; acting on it would not have been, and
  `image: ghcr.io/your-org/...` ships as a placeholder, so a wrong host here is
  an ordinary state for a real repository rather than a contrived one.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Generators.DeployArtifacts
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{EnvironmentRepository, Sops, Steps}

  @domain "drill.example.com"

  @moduletag :sops

  # The guard sits behind `check_secrets`, so an environment with no secrets
  # never reaches it. Written without this, three of these tests passed while
  # asserting nothing — the run was stopping at "uat has no age key yet" and
  # the absence of a mismatch message proved only that the guard had not run.
  setup do
    Sops.available?() ||
      raise """
      sops and age are not installed, and these tests are meaningless without
      them — the guard under test sits behind `check_secrets`, so every one of
      them would pass having never reached it.

      This module is tagged `:sops` and excluded by default; you have asked for
      it explicitly. Install them (brew install sops age) or drop the tag.
      """

    tmp = CodeMySpec.TempFile.owned_dir("deploy_config_target")
    scope = %{full_scope_fixture() | environment: Environment.new(:local, tmp)}

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{domain: @domain})

    scope = %{scope | active_project: project}
    {:ok, _} = EnvironmentRepository.put(scope, "uat", %{})

    {:ok, {public, private}} = Sops.generate_key()
    ProjectSecrets.put_value(scope, "age_private_key_uat", private)
    :ok = Sops.write_config(scope.environment, %{"uat" => public})
    :ok = Sops.put_secret(scope.environment, "uat", "SECRET_KEY_BASE", "x", private)
    :ok = Sops.put_secret(scope.environment, "uat", "DATABASE_URL", "ecto://x", private)

    File.mkdir_p!(Path.join(tmp, "config"))
    write_boilerplate(tmp)
    {:ok, scope: scope, tmp: tmp}
  end

  # The deploy step audits the checkout before it builds anything, so a project
  # carrying only a kamal config is refused for the eight artifacts it is
  # missing and never reaches the guard these tests are about. Giving the
  # fixture what `cms new` would have given it puts the config mismatch back to
  # being the only thing wrong with the project.
  #
  # `.sops.yaml` and `envs/uat.enc.env` are skipped: the setup above wrote real
  # ones with a real key, and the generator ships placeholders. Overwriting
  # them left `check_secrets` failing with "sops metadata not found", which is
  # `reaches_the_guard!/1` doing its job — the tests would otherwise have been
  # asserting on a run that stopped two steps early.
  @generated_by_setup ["config/deploy.uat.yml", ".sops.yaml", "envs/uat.enc.env"]

  defp write_boilerplate(tmp) do
    for {path, body} <-
          DeployArtifacts.files(
            app: "my_app",
            host: @domain,
            registry: "ghcr.io",
            owner: "acme"
          ),
        path not in @generated_by_setup do
      full = Path.join(tmp, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, body)
    end
  end

  defp write_config(tmp, host) do
    File.write!(Path.join(tmp, "config/deploy.uat.yml"), """
    service: drill-uat
    servers:
      web:
        - #{host}
    proxy:
      ssl: true
      host: #{host}
    """)
  end

  # Anchors every test below: if the run stops at secrets, a missing mismatch
  # message means nothing.
  defp reaches_the_guard!(scope) do
    assert {:ok, _} = Steps.check_secrets(scope, "uat"),
           "the deploy guard runs after check_secrets, so these tests only mean " <>
             "something when the secrets are in place"
  end

  describe "a config naming a host the project does not own" do
    test "refuses, naming both hosts", ctx do
      reaches_the_guard!(ctx.scope)
      write_config(ctx.tmp, "uat.astralbi.com")

      assert {:error, message} = Steps.run(:deploy, ctx.scope, environment: "uat")

      assert message =~ "uat.astralbi.com",
             "the refusal has to name the host the config would deploy to"

      assert message =~ "uat.#{@domain}",
             "and the host it should have been, or Sam cannot tell which end is wrong"
    end

    # The deploy must not have happened. Checking only the message would pass
    # just as well if the guard reported a mismatch after kamal had already
    # changed the machine, which is the failure being prevented.
    test "does not reach the deploy script", ctx do
      reaches_the_guard!(ctx.scope)
      write_config(ctx.tmp, "uat.astralbi.com")

      # `bin/deploy` is present now — the fixture carries the whole boilerplate
      # so the run gets past the deploy-readiness audit. Its absence used to be
      # the proof; the proof is now that the script left no trace. It refuses a
      # dirty tree before anything else and would have written `.kamal/` on the
      # way to kamal, so neither existing means it was never invoked.
      assert File.exists?(Path.join(ctx.tmp, "bin/deploy"))

      assert {:error, message} = Steps.run(:deploy, ctx.scope, environment: "uat")

      refute File.exists?(Path.join(ctx.tmp, ".kamal")),
             "the deploy script ran — the host mismatch was reported after the fact"

      refute message =~ "working tree is dirty",
             "expected the host mismatch to stop the run before the script was invoked"
    end
  end

  describe "a config naming this project's own host" do
    test "passes the guard and fails later, on its own terms", ctx do
      reaches_the_guard!(ctx.scope)
      write_config(ctx.tmp, "uat.#{@domain}")

      assert {:error, message} = Steps.run(:deploy, ctx.scope, environment: "uat")

      refute message =~ "will not deploy to a host",
             "the config points at this project's uat, so the guard has nothing to say"
    end
  end

  # `mix cms.new` now emits the host as ERB, because the alternative is a
  # committed hostname and a committed server IP — and the IP is not knowable
  # when the file is written, since the box does not exist until setup makes
  # one, and is a different box on every provision. That is what the
  # `<UAT_HOST_IP>` placeholder was standing in for.
  describe "a config that resolves its host at deploy time" do
    test "is allowed, because this step is what sets the value", ctx do
      reaches_the_guard!(ctx.scope)

      File.write!(Path.join(ctx.tmp, "config/deploy.uat.yml"), """
      service: drill-uat
      proxy:
        host: <%= ENV["CMS_DEPLOY_HOST"] || "<UAT_HOST>" %>
      """)

      result = Steps.run(:deploy, ctx.scope, environment: "uat")

      refute match?({:error, message} when is_binary(message), result) and
               elem(result, 1) =~ "will not deploy to a host",
             "the host comes from CMS_DEPLOY_HOST, which this step sets from " <>
               "this project's domain — there is nothing here to disagree with"
    end

    # The guard still has teeth for the case it was written for: a literal
    # hostname belonging to somebody else.
    test "a literal wrong host is still refused", ctx do
      reaches_the_guard!(ctx.scope)

      File.write!(Path.join(ctx.tmp, "config/deploy.uat.yml"), """
      service: drill-uat
      proxy:
        host: uat.someone-elses-app.com
      """)

      assert {:error, message} = Steps.run(:deploy, ctx.scope, environment: "uat")
      assert message =~ "will not deploy to a host"
    end
  end

  describe "a config that cannot be parsed" do
    # Deliberately not this guard's business. Missing and malformed deploy
    # files belong to `Generators.DeployBoilerplate`; inventing a second
    # opinion here would report the same problem twice and disagree about it.
    test "is left alone rather than reported as a mismatch", ctx do
      reaches_the_guard!(ctx.scope)
      File.write!(Path.join(ctx.tmp, "config/deploy.uat.yml"), "{{ not yaml")

      assert {:error, message} = Steps.run(:deploy, ctx.scope, environment: "uat")

      refute message =~ "will not deploy to a host",
             "a file this guard cannot read is not evidence of a wrong host"
    end
  end
end
