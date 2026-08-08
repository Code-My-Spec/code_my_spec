defmodule CodeMySpec.Provisioning.SecretsVerifyTest do
  @moduledoc """
  Whether the secrets step notices that its key no longer opens its own file.

  Half the pair lives in the repository — `.sops.yaml` names the public
  recipient — and half in the database. Nothing kept them in step, and git
  moves tracked files around: a checkout, a revert, a bad merge, a teammate
  committing their own. When they drift, sops can still encrypt, because
  encrypting only needs the recipient; nothing can decrypt.

  Checking only that a key existed made that unrecoverable rather than merely
  broken. `run_step/3` verifies before it executes, so re-running the secrets
  step found it satisfied and never reached the code that would have rewritten
  `.sops.yaml` from fresh keys.

  Real sops and age throughout — the claim is about whether a keypair actually
  corresponds, which only the real tools can answer.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{Sops, Steps}

  @moduletag :sops

  setup do
    case Sops.available?() do
      false ->
        {:ok, skip: true}

      true ->
        {:ok, tmp} = Briefly.create(directory: true)
        scope = %{full_scope_fixture() | environment: Environment.new(:local, tmp)}
        {:ok, scope: scope, tmp: tmp}
    end
  end

  defp key_for(scope, environment) do
    {:ok, {public, private}} = Sops.generate_key()
    ProjectSecrets.put_value(scope, "age_private_key_#{environment}", private)
    {public, private}
  end

  describe "a key that matches its file" do
    test "is satisfied", ctx do
      unless ctx[:skip] do
        {public, _} = key_for(ctx.scope, "prod")
        :ok = Sops.write_config(ctx.scope.environment, %{"prod" => public})
        :ok = Sops.put_secret(ctx.scope.environment, "prod", "K", "v", stored(ctx.scope, "prod"))

        assert {:ok, :satisfied, _} = Steps.verify(:secrets, ctx.scope, environments: ["prod"])
      end
    end
  end

  describe "a key that no longer matches its file" do
    # The exact accident from the report: `.sops.yaml` restored from git while
    # the database kept the key a previous run generated. One ordinary command,
    # aimed at an unrelated problem.
    test "reports absent, so re-running the step repairs it", ctx do
      unless ctx[:skip] do
        {public, _} = key_for(ctx.scope, "prod")
        :ok = Sops.write_config(ctx.scope.environment, %{"prod" => public})
        :ok = Sops.put_secret(ctx.scope.environment, "prod", "K", "v", stored(ctx.scope, "prod"))

        # Someone else's recipient arrives, and the file is re-encrypted to it.
        {:ok, {other_public, other_private}} = Sops.generate_key()
        :ok = Sops.write_config(ctx.scope.environment, %{"prod" => other_public})
        File.rm!(Path.join(ctx.tmp, "envs/prod.enc.env"))
        :ok = Sops.put_secret(ctx.scope.environment, "prod", "K", "v", other_private)

        assert {:ok, :absent} = Steps.verify(:secrets, ctx.scope, environments: ["prod"]),
               "expected drift to report absent — reporting satisfied is what made it unrecoverable"
      end
    end
  end

  describe "an environment with no key at all" do
    test "is absent", ctx do
      unless ctx[:skip] do
        assert {:ok, :absent} = Steps.verify(:secrets, ctx.scope, environments: ["prod"])
      end
    end
  end

  describe "a key with no file yet" do
    # A first run has a key and nothing encrypted. That is not drift — there is
    # nothing to be out of step with — and reporting absent would leave the
    # step unable to ever finish.
    test "is satisfied on the key alone", ctx do
      unless ctx[:skip] do
        key_for(ctx.scope, "prod")

        assert {:ok, :satisfied, _} = Steps.verify(:secrets, ctx.scope, environments: ["prod"])
      end
    end
  end

  describe "running the step again over a working environment" do
    # The step re-runs whenever *any* environment needs attention, so adding a
    # second one puts the first through this path. Minting unconditionally
    # rewrote `.sops.yaml` to fresh recipients while the existing `.enc.env`
    # stayed encrypted to the old ones — whose private halves the same loop had
    # just overwritten. The secret became unreadable by anyone, permanently.
    #
    # A drill hit it on the ordinary path: cycle 1 encrypted to one key, cycle
    # 2 rewrote the config, and the deploy failed with "no identity matched any
    # of the recipients".
    test "keeps the existing key, so secrets stay readable", ctx do
      unless ctx[:skip] do
        {:ok, _} = Steps.run(:secrets, ctx.scope, environments: ["uat"])
        first = stored(ctx.scope, "uat")

        :ok = Sops.put_secret(ctx.scope.environment, "uat", "SECRET_KEY_BASE", "s3kr1t", first)

        # A second environment arrives. uat is untouched and working.
        {:ok, _} = Steps.run(:secrets, ctx.scope, environments: ["uat", "prod"])

        assert stored(ctx.scope, "uat") == first,
               "uat's key was replaced while it was still opening its own file"

        assert {:ok, %{"SECRET_KEY_BASE" => "s3kr1t"}} =
                 Sops.decrypt(ctx.scope.environment, "uat", stored(ctx.scope, "uat")),
               "the secret set before the re-run must still be readable afterwards"
      end
    end

    # The other half: a key that genuinely cannot open its file must still be
    # replaced, or the repair path in `verify(:secrets, ...)` has nothing to
    # repair with. The contents are already unrecoverable at that point.
    test "still replaces a key that no longer opens its file", ctx do
      unless ctx[:skip] do
        {public, _} = key_for(ctx.scope, "prod")
        :ok = Sops.write_config(ctx.scope.environment, %{"prod" => public})
        :ok = Sops.put_secret(ctx.scope.environment, "prod", "K", "v", stored(ctx.scope, "prod"))

        # Someone else's recipient arrives; the stored key no longer matches.
        {:ok, {other_public, other_private}} = Sops.generate_key()
        :ok = Sops.write_config(ctx.scope.environment, %{"prod" => other_public})
        File.rm!(Path.join(ctx.tmp, "envs/prod.enc.env"))
        :ok = Sops.put_secret(ctx.scope.environment, "prod", "K", "v", other_private)

        before = stored(ctx.scope, "prod")
        {:ok, _} = Steps.run(:secrets, ctx.scope, environments: ["prod"])

        refute stored(ctx.scope, "prod") == before,
               "drift is the case where minting a fresh key is the only way forward"
      end
    end
  end

  defp stored(scope, environment) do
    {:ok, private} = ProjectSecrets.fetch_value(scope, "age_private_key_#{environment}")
    private
  end
end
