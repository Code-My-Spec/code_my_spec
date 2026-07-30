defmodule CodeMySpec.Provisioning.SopsTest do
  @moduledoc """
  Exercises the real `sops` and `age` binaries rather than stubbing them.

  Stubbing would defeat the purpose: every property story 967 cares about —
  that the file is genuinely unreadable, that one environment's key cannot
  open another's, that no plaintext lands on disk — is a property of the
  actual crypto and the actual file format. A fake would assert our beliefs
  about sops rather than sops.

  Skipped when the binaries are absent, so a machine without them reports a
  skip instead of a failure that looks like a code defect.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Provisioning.Sops

  @moduletag :sops

  setup_all do
    case Sops.available?() do
      true -> :ok
      false -> {:ok, skip: true}
    end
  end

  setup context do
    case Sops.available?() do
      false ->
        {:ok, skip: true}

      true ->
        {:ok, tmp} = Briefly.create(directory: true)
        env = Environment.new(:local, tmp)

        {:ok, {uat_pub, uat_priv}} = Sops.generate_key()
        {:ok, {prod_pub, prod_priv}} = Sops.generate_key()
        :ok = Sops.write_config(env, %{"uat" => uat_pub, "prod" => prod_pub})

        Map.merge(context, %{
          env: env,
          tmp: tmp,
          uat: %{pub: uat_pub, priv: uat_priv},
          prod: %{pub: prod_pub, priv: prod_priv}
        })
        |> then(&{:ok, &1})
    end
  end

  describe "generate_key/0" do
    test "returns a distinct public and private key each time" do
      {:ok, {pub_a, priv_a}} = Sops.generate_key()
      {:ok, {pub_b, priv_b}} = Sops.generate_key()

      assert String.starts_with?(pub_a, "age1")
      assert String.starts_with?(priv_a, "AGE-SECRET-KEY-")
      refute pub_a == pub_b
      refute priv_a == priv_b
    end
  end

  describe "a secret written to an environment" do
    # Criterion 7997: the plaintext must appear nowhere a `git add` could
    # sweep it up — not in the encrypted file, not in a scratch file.
    test "is ciphertext in the file, and plaintext nowhere in the tree", ctx do
      :ok = Sops.put_secret(ctx.env, "prod", "RESEND_API_KEY", "re_live_plaintext", ctx.prod.priv)

      {:ok, contents} = Environments.read_file(ctx.env, "envs/prod.enc.env")

      # Anchor: the key name IS present, so the refute below is not passing
      # against an empty or absent file.
      assert contents =~ "RESEND_API_KEY"
      assert contents =~ "ENC["
      refute contents =~ "re_live_plaintext"

      assert plaintext_hits(ctx.tmp, "re_live_plaintext") == []
    end

    test "round-trips through the environment's own key", ctx do
      :ok = Sops.put_secret(ctx.env, "prod", "DATABASE_URL", "ecto://prod", ctx.prod.priv)

      assert {:ok, %{"DATABASE_URL" => "ecto://prod"}} =
               Sops.decrypt(ctx.env, "prod", ctx.prod.priv)
    end
  end

  describe "one key per environment" do
    setup ctx do
      :ok = Sops.put_secret(ctx.env, "prod", "DATABASE_URL", "ecto://prod", ctx.prod.priv)
      :ok = Sops.put_secret(ctx.env, "uat", "DATABASE_URL", "ecto://uat", ctx.uat.priv)
      :ok
    end

    # Criterion 8053. This is the blast radius the design exists to close:
    # with a single project-wide key, whoever can deploy staging can read
    # production.
    test "UAT's key cannot read production's file", ctx do
      assert {:error, _} = Sops.decrypt(ctx.env, "prod", ctx.uat.priv)
    end

    test "UAT's key cannot write production's file either", ctx do
      # `sops set` has to decrypt the data key before it can add a value, so
      # the isolation covers writes as well as reads. Worth pinning: a design
      # that let the wrong key *append* would leak nothing but would let an
      # attacker with UAT access corrupt production's config.
      assert {:error, _} = Sops.put_secret(ctx.env, "prod", "X", "y", ctx.uat.priv)
    end

    test "each environment's own key still works", ctx do
      assert {:ok, %{"DATABASE_URL" => "ecto://prod"}} =
               Sops.decrypt(ctx.env, "prod", ctx.prod.priv)

      assert {:ok, %{"DATABASE_URL" => "ecto://uat"}} =
               Sops.decrypt(ctx.env, "uat", ctx.uat.priv)
    end

    test "each file records only its own recipient", ctx do
      assert {:ok, [ctx.prod.pub]} == Sops.recipients(ctx.env, "prod")
      assert {:ok, [ctx.uat.pub]} == Sops.recipients(ctx.env, "uat")
    end
  end

  describe "missing_secrets/4" do
    # Criterion 8000: a boot that refuses must name the absent key, rather
    # than starting and failing later on whatever path needed it.
    test "names the absent key and not the present one", ctx do
      :ok = Sops.put_secret(ctx.env, "prod", "DATABASE_URL", "ecto://prod", ctx.prod.priv)

      assert {:ok, ["SECRET_KEY_BASE"]} =
               Sops.missing_secrets(ctx.env, "prod", ctx.prod.priv, [
                 "DATABASE_URL",
                 "SECRET_KEY_BASE"
               ])
    end

    test "is empty when everything required is present", ctx do
      :ok = Sops.put_secret(ctx.env, "prod", "DATABASE_URL", "ecto://prod", ctx.prod.priv)

      assert {:ok, []} = Sops.missing_secrets(ctx.env, "prod", ctx.prod.priv, ["DATABASE_URL"])
    end
  end

  describe "write_config/2" do
    test "maps each environment to its own recipient", ctx do
      {:ok, yaml} = Environments.read_file(ctx.env, ".sops.yaml")

      # Dots are escaped because the field is a path_regex, not a path.
      assert yaml =~ ~S(envs/uat\.enc\.env$)
      assert yaml =~ ~S(envs/prod\.enc\.env$)
      assert yaml =~ ctx.uat.pub
      assert yaml =~ ctx.prod.pub
    end
  end

  defp plaintext_hits(dir, needle) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(&(File.read!(&1) =~ needle))
  end
end
