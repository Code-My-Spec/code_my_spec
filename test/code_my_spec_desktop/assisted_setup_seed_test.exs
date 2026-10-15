defmodule CodeMySpecDesktop.AssistedSetupSeedTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents

  @seed Path.expand("../../priv/repo/qa_1112_assisted_setup_seed.exs", __DIR__)

  setup do
    previous_env = Application.get_env(:code_my_spec, :env)
    previous_args = System.argv()

    on_exit(fn ->
      System.argv(previous_args)

      restore_environment(previous_env)
    end)

    :ok
  end

  defp restore_environment(nil), do: Application.delete_env(:code_my_spec, :env)

  defp restore_environment(value),
    do: Application.put_env(:code_my_spec, :env, value)

  test "refuses use outside the desktop environment" do
    Application.put_env(:code_my_spec, :env, :test)
    System.argv(["qa1112_seed_test", Ecto.UUID.generate()])

    assert_raise Mix.Error, "Run this seed with MIX_ENV=desktop.", fn ->
      Code.eval_file(@seed)
    end
  end

  test "refuses a shared database name before changing settings" do
    Application.put_env(:code_my_spec, :env, :desktop)
    System.argv(["code_my_spec_desktop", Ecto.UUID.generate()])

    assert_raise Mix.Error, ~r/disposable database name/, fn ->
      Code.eval_file(@seed)
    end
  end

  test "refuses a QA name that does not match the connected database" do
    Application.put_env(:code_my_spec, :env, :desktop)
    database = "qa1112_" <> String.replace(Ecto.UUID.generate(), "-", "")
    System.argv([database, Ecto.UUID.generate()])

    assert_raise Mix.Error, ~r/Connected database does not match/, fn ->
      Code.eval_file(@seed)
    end
  end

  test "the explicit local provider resolves without storing an integration credential" do
    scope = full_scope_fixture()
    assert {:ok, setting} = Agents.put_model_setting(scope, :main, "claude-code", nil)
    assert setting.user_id == scope.user.id
    assert {:ok, {"claude-code", nil}, :set} = Agents.resolve_model(scope, :main)
    assert {:ok, repeated} = Agents.put_model_setting(scope, :main, "claude-code", nil)
    assert repeated.id == setting.id
  end
end
