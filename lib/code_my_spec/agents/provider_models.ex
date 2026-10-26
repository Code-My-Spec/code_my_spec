defmodule CodeMySpec.Agents.ProviderModels do
  @moduledoc """
  The models an API provider serves this account, from its own `/models`.

  The keys for Anthropic, z.ai and DeepInfra live on the server
  (`Agents.Credential`), so the server asks. Codex and the Claude CLI run on a
  machine's own login and are reported by its harness instead
  (`Agents.ServedModels`).

  Cached per account and provider: a list for ten minutes, a failure for one, so
  a settings page and every agent start do not each make the call. A failure is
  `:unknown`, which callers allow: an unreachable provider never blocks.
  """

  require Logger

  @ttl_ms :timer.minutes(10)
  @failure_ttl_ms :timer.minutes(1)

  @endpoints %{
    "anthropic" => "https://api.anthropic.com/v1/models",
    "zai" => "https://api.z.ai/api/coding/paas/v4/models",
    "deepinfra" => "https://api.deepinfra.com/v1/openai/models"
  }

  @doc "The API providers whose keys live on the server; the rest are listed by their harness."
  @spec providers() :: [String.t()]
  def providers, do: Map.keys(@endpoints)

  @doc "The model ids `provider` serves for `api_key`, cached under `account_id`."
  @spec list(String.t(), String.t(), String.t()) :: {:ok, [String.t()]} | :unknown
  def list(account_id, provider, api_key)
      when is_map_key(@endpoints, provider) and is_binary(api_key) do
    key = {__MODULE__, account_id, provider}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(key, nil) do
      {expires, result} when expires > now ->
        result

      _stale_or_none ->
        result = fetch(provider, api_key)
        ttl = if result == :unknown, do: @failure_ttl_ms, else: @ttl_ms
        :persistent_term.put(key, {now + ttl, result})
        result
    end
  end

  def list(_account_id, _provider, _api_key), do: :unknown

  defp fetch(provider, api_key) do
    [url: Map.fetch!(@endpoints, provider), headers: headers(provider, api_key), retry: false]
    |> Keyword.merge(Application.get_env(:code_my_spec, __MODULE__, []))
    |> Req.get()
    |> case do
      {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) ->
        ids = for %{"id" => id} when is_binary(id) <- models, do: id
        if ids == [], do: :unknown, else: {:ok, ids}

      other ->
        Logger.info("[ProviderModels] #{provider} did not list its models: #{describe(other)}")
        :unknown
    end
  end

  defp headers("anthropic", api_key),
    do: [{"x-api-key", api_key}, {"anthropic-version", "2023-06-01"}]

  defp headers(_openai_style, api_key), do: [{"authorization", "Bearer " <> api_key}]

  defp describe({:ok, %{status: status}}), do: "HTTP #{status}"
  defp describe({:error, error}), do: inspect(error)
end
