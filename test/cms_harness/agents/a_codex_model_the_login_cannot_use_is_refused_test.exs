defmodule CmsHarness.Agents.ACodexModelTheLoginCannotUseIsRefusedTest do
  @moduledoc """
  Issue 4d4db6fb: Codex agent d5c90ae2 was given `gpt-5.4-mini`, which the
  Codex CLI refuses on a ChatGPT login, and failed every turn with a 400. The
  login's models are in its home's `models_cache.json`, so an agent asking for
  one it does not serve is refused at start.
  """
  # Not async: the recorded CLI, pinned for the whole suite, is lifted here.
  use ExUnit.Case, async: false

  alias CmsHarness.Agents.Provider

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    pinned = Application.fetch_env!(:code_my_spec, Provider)
    Application.delete_env(:code_my_spec, Provider)
    on_exit(fn -> Application.put_env(:code_my_spec, Provider, pinned) end)

    File.write!(
      Path.join(home, "models_cache.json"),
      Jason.encode!(%{"models" => [%{"slug" => "gpt-6.1-sol"}, %{"slug" => "gpt-5.6-terra"}]})
    )

    %{credential: %{"codex_home" => home}}
  end

  test "a model the login does not serve is refused, naming the ones it does",
       %{credential: credential} do
    assert {:error, {:model_not_available, message}} =
             Provider.options("openai-codex", credential, model: "gpt-5.4-mini")

    assert message =~ ~s("gpt-5.4-mini")
    assert message =~ "gpt-6.1-sol, gpt-5.6-terra"
  end

  test "a model the login serves starts", %{credential: credential} do
    assert {:ok, opts} = Provider.options("openai-codex", credential, model: "gpt-5.6-terra")
    assert {Alloy.Provider.Codex, %{model: "gpt-5.6-terra"}} = Keyword.fetch!(opts, :provider)
  end

  test "no model asked for leaves it to the login", %{credential: credential} do
    assert {:ok, _opts} = Provider.options("openai-codex", credential)
  end

  test "a home with no cache says nothing about models", %{tmp_dir: home} do
    File.rm!(Path.join(home, "models_cache.json"))

    assert {:ok, _opts} =
             Provider.options("openai-codex", %{"codex_home" => home}, model: "anything")
  end
end
