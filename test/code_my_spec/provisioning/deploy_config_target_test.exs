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
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{EnvironmentRepository, Sops, Steps}

  @domain "drill.example.com"

  @moduletag :sops

  # The guard sits behind `check_secrets`, so an environment with no secrets
  # never reaches it. Written without this, three of these tests passed while
  # asserting nothing — the run was stopping at "uat has no age key yet" and
  # the absence of a mismatch message proved only that the guard had not run.
  setup do
    case Sops.available?() do
      false ->
        {:ok, skip: true}

      true ->
        {:ok, tmp} = Briefly.create(directory: true)
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
        {:ok, scope: scope, tmp: tmp}
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
      unless ctx[:skip] do
        reaches_the_guard!(ctx.scope)
        write_config(ctx.tmp, "uat.astralbi.com")

        assert {:error, message} = Steps.run(:deploy, ctx.scope, environment: "uat")

        assert message =~ "uat.astralbi.com",
               "the refusal has to name the host the config would deploy to"

        assert message =~ "uat.#{@domain}",
               "and the host it should have been, or Sam cannot tell which end is wrong"
      end
    end

    # The deploy must not have happened. Checking only the message would pass
    # just as well if the guard reported a mismatch after kamal had already
    # changed the machine, which is the failure being prevented.
    test "does not reach the deploy script", ctx do
      unless ctx[:skip] do
        reaches_the_guard!(ctx.scope)
        write_config(ctx.tmp, "uat.astralbi.com")

        refute File.exists?(Path.join(ctx.tmp, "bin/deploy")),
               "no deploy script exists, so reaching it would surface as a different error"

        assert {:error, message} = Steps.run(:deploy, ctx.scope, environment: "uat")

        refute message =~ "bin/deploy",
               "expected the host mismatch to stop the run before the script was required"
      end
    end
  end

  describe "a config naming this project's own host" do
    test "passes the guard and fails later, on its own terms", ctx do
      unless ctx[:skip] do
        reaches_the_guard!(ctx.scope)
        write_config(ctx.tmp, "uat.#{@domain}")

        assert {:error, message} = Steps.run(:deploy, ctx.scope, environment: "uat")

        refute message =~ "will not deploy to a host",
               "the config points at this project's uat, so the guard has nothing to say"
      end
    end
  end

  describe "a config that cannot be parsed" do
    # Deliberately not this guard's business. Missing and malformed deploy
    # files belong to `Generators.DeployBoilerplate`; inventing a second
    # opinion here would report the same problem twice and disagree about it.
    test "is left alone rather than reported as a mismatch", ctx do
      unless ctx[:skip] do
        reaches_the_guard!(ctx.scope)
        File.write!(Path.join(ctx.tmp, "config/deploy.uat.yml"), "{{ not yaml")

        assert {:error, message} = Steps.run(:deploy, ctx.scope, environment: "uat")

        refute message =~ "will not deploy to a host",
               "a file this guard cannot read is not evidence of a wrong host"
      end
    end
  end
end
