defmodule CodeMySpec.Agents.ProviderModelsTest do
  @moduledoc """
  The API providers' own `/models` lists, read with the account's key (served
  models, phase 2). Cassettes are hand-authored from each API's documented
  response shape, with the key filtered out; re-record against the live APIs
  with `mode: :record` and a real key in scope.
  """
  use CodeMySpecTest.DataCase, async: false

  import ReqCassette
  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.ProviderModels

  @cassette_dir "test/cassettes/provider_models"

  setup do
    prior = Application.get_env(:code_my_spec, ProviderModels)
    on_exit(fn -> Application.put_env(:code_my_spec, ProviderModels, prior) end)
    %{prior: prior}
  end

  defp with_provider_cassette(name, fun) do
    prior = Application.get_env(:code_my_spec, ProviderModels)

    with_cassette(name, cassette_opts(), fn plug ->
      Application.put_env(:code_my_spec, ProviderModels, plug: plug)
      fun.()
      Application.put_env(:code_my_spec, ProviderModels, prior)
    end)
  end

  defp cassette_opts,
    do: [
      cassette_dir: @cassette_dir,
      mode: :replay,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization", "x-api-key"]
    ]

  defp account, do: Ecto.UUID.generate()

  test "each API provider lists the models it serves" do
    for {provider, cassette, expected} <- [
          {"anthropic", "anthropic_models", "claude-opus-5-5"},
          {"zai", "zai_models", "glm-5.3"},
          {"deepinfra", "deepinfra_models", "deepseek-ai/DeepSeek-V3.1"}
        ] do
      with_provider_cassette(cassette, fn ->
        assert {:ok, models} = ProviderModels.list(account(), provider, "test-key")
        assert expected in models, "#{provider} did not list #{expected}"
      end)
    end
  end

  test "a provider that does not answer is unknown, never a block" do
    # The suite's default plug answers 404.
    assert ProviderModels.list(account(), "anthropic", "test-key") == :unknown
    assert ProviderModels.list(account(), "a-provider-with-no-list", "test-key") == :unknown
  end

  test "an anthropic default the account's key cannot use resolves to the login's default" do
    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    with_provider_cassette("anthropic_models", fn ->
      # The cassette lists claude-sonnet-5 (coding's anthropic default), so it stays.
      assert {:ok, {"anthropic", "claude-sonnet-5"}, :default} =
               Agents.resolve_model(scope, :coding)

      assert {:error, {:model_not_served, _served}} =
               Agents.put_model_setting(scope, :qa, "anthropic", "claude-retired-1")
    end)
  end
end
