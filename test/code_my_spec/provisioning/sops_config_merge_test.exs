defmodule CodeMySpec.Provisioning.SopsConfigMergeTest do
  @moduledoc """
  Issue 5850ece7: metric_flow committed its own `.sops.yaml` rule for a local
  keyring (`envs/(dev|test)\\.`, a different file convention than this
  step's own `envs/<env>.enc.env$`). `write_config/2` rendered the whole
  file from its own recipients map alone, so every secrets run silently
  dropped that rule and `just init-worktree` could no longer re-encrypt the
  files it covered.

  Real sops and age throughout, same as `SopsTest` -- the claim is that the
  file sops itself reads back still carries the foreign rule, which only the
  real tool can confirm.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Provisioning.Sops

  @moduletag :sops

  @foreign_rule """
    - path_regex: envs/(dev|test)\\.
      age: age1foreignlocalkeyringxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  """

  setup_all do
    setup_all_result(Sops.available?())
  end

  defp setup_all_result(true), do: :ok
  defp setup_all_result(false), do: {:ok, skip: true}

  setup context do
    build_context(context, Sops.available?())
  end

  defp build_context(context, true) do
    tmp = CodeMySpec.TempFile.owned_dir("test")
    env = ExecutionContext.new(:local, tmp)
    {:ok, {prod_pub, _priv}} = Sops.generate_key()

    Map.merge(context, %{env: env, tmp: tmp, prod_pub: prod_pub})
    |> then(&{:ok, &1})
  end

  defp build_context(_context, false), do: {:ok, skip: true}

  describe "write_config/2" do
    test "keeps a rule it does not own that was already committed to the file", ctx do
      :ok =
        ExecutionContexts.write_file(ctx.env, ".sops.yaml", """
        creation_rules:
        #{@foreign_rule}
        """)

      :ok = Sops.write_config(ctx.env, %{"prod" => ctx.prod_pub})

      {:ok, contents} = ExecutionContexts.read_file(ctx.env, ".sops.yaml")
      assert contents =~ "envs/(dev|test)"

      assert {:ok, %{"creation_rules" => rules}} = YamlElixir.read_from_string(contents)
      assert Enum.any?(rules, &(&1["path_regex"] == "envs/(dev|test)\\."))
      assert Enum.any?(rules, &(&1["path_regex"] == "envs/prod\\.enc\\.env$"))
    end

    test "keeps the foreign rule across repeated runs, not just the first one", ctx do
      :ok =
        ExecutionContexts.write_file(ctx.env, ".sops.yaml", """
        creation_rules:
        #{@foreign_rule}
        """)

      :ok = Sops.write_config(ctx.env, %{"prod" => ctx.prod_pub})
      {:ok, {prod_pub_2, _priv}} = Sops.generate_key()
      :ok = Sops.write_config(ctx.env, %{"prod" => prod_pub_2})

      {:ok, contents} = ExecutionContexts.read_file(ctx.env, ".sops.yaml")
      {:ok, %{"creation_rules" => rules}} = YamlElixir.read_from_string(contents)

      assert Enum.count(rules, &(&1["path_regex"] == "envs/(dev|test)\\.")) == 1

      assert Enum.find(rules, &(&1["path_regex"] == "envs/prod\\.enc\\.env$"))["age"] ==
               prod_pub_2
    end

    test "still replaces its own rule's recipient rather than keeping the old one too", ctx do
      :ok = Sops.write_config(ctx.env, %{"prod" => ctx.prod_pub})
      {:ok, {prod_pub_2, _priv}} = Sops.generate_key()
      :ok = Sops.write_config(ctx.env, %{"prod" => prod_pub_2})

      {:ok, contents} = ExecutionContexts.read_file(ctx.env, ".sops.yaml")
      {:ok, %{"creation_rules" => rules}} = YamlElixir.read_from_string(contents)

      own_rules = Enum.filter(rules, &(&1["path_regex"] == "envs/prod\\.enc\\.env$"))
      assert own_rules == [%{"path_regex" => "envs/prod\\.enc\\.env$", "age" => prod_pub_2}]
    end

    test "an encrypted file the kept rule covers still decrypts after a later write_config",
         ctx do
      {:ok, {foreign_pub, foreign_priv}} = Sops.generate_key()

      :ok =
        ExecutionContexts.write_file(ctx.env, ".sops.yaml", """
        creation_rules:
          - path_regex: envs/dev\\.local\\.env$
            age: #{foreign_pub}
        """)

      :ok =
        ExecutionContexts.write_file(ctx.env, "envs/dev.local.env", "LOCAL_ONLY=test-dev-value\n")

      {_out, 0} =
        ExecutionContexts.cmd(ctx.env, "sops", ["encrypt", "-i", "envs/dev.local.env"],
          cd: ctx.env.cwd
        )

      :ok = Sops.write_config(ctx.env, %{"prod" => ctx.prod_pub})

      {out, 0} =
        ExecutionContexts.cmd(ctx.env, "sops", ["decrypt", "envs/dev.local.env"],
          cd: ctx.env.cwd,
          env: [{"SOPS_AGE_KEY", foreign_priv}]
        )

      assert out =~ "LOCAL_ONLY=test-dev-value"
    end
  end
end
