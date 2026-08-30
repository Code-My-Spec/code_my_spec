defmodule CodeMySpec.Integrations.Providers.ApiKey do
  @moduledoc """
  Providers whose credential is a key somebody pastes, and the request that
  proves one works.

  Every other provider here proves its credential by completing an OAuth
  exchange — the token exists only because the provider issued it. A pasted key
  is a string somebody typed, so it proves nothing until the provider is asked,
  and a key stored unasked makes the settings page report a connection whose
  first evidence arrives when an agent fails a model call minutes later.

  One table rather than a `case` per provider, for the same reason
  `Agents.Providers` is one: adding a provider should be adding a row.

  ## Three answers, not two

  `:ok` and `{:error, :rejected}` are the two the user cares about. The third —
  the provider answered something else, or did not answer — is deliberately not
  folded into either. Collapsing it into `:rejected` tells someone their key is
  bad when the provider was down; collapsing it into `:ok` stores a key nothing
  has vouched for, which is the failure this module exists to prevent.
  """

  @providers %{
    anthropic: %{
      label: "Anthropic",
      method: :get,
      url: "https://api.anthropic.com/v1/models",
      # Anthropic authenticates with its own header rather than a bearer token,
      # and refuses any request without a version.
      auth: {:header, "x-api-key"},
      headers: [{"anthropic-version", "2023-06-01"}],
      json: nil
    },
    zai: %{
      label: "Z.ai",
      method: :post,
      url: "https://api.z.ai/api/paas/v4/chat/completions",
      auth: :bearer,
      headers: [],
      # Z.ai publishes no endpoint that authenticates without doing work, so the
      # check is the smallest completion there is. A models list would be
      # cheaper and does not exist; a 404 from a guessed one would read as
      # "answered something other than 401", which this module treats as
      # unknown rather than valid — correct, and useless as a check.
      json: %{
        model: "glm-5.3",
        messages: [%{role: "user", content: "hi"}],
        max_tokens: 1
      }
    }
  }

  @type provider :: :anthropic | :zai
  @type failure :: :rejected | {:unexpected, pos_integer()} | {:unreachable, term()}

  @doc "The providers connected by pasting a key."
  @spec names() :: [provider()]
  def names, do: @providers |> Map.keys() |> Enum.sort()

  @spec known?(atom()) :: boolean()
  def known?(provider), do: Map.has_key?(@providers, provider)

  @doc "What to call this provider on a page."
  @spec label(provider()) :: String.t()
  def label(provider), do: @providers |> Map.fetch!(provider) |> Map.fetch!(:label)

  @doc """
  Ask the provider whether this key works.
  """
  @spec verify(atom(), String.t()) :: :ok | {:error, failure()}
  def verify(provider, key) when is_binary(key) do
    case Map.fetch(@providers, provider) do
      {:ok, spec} -> request(spec, key)
      :error -> {:error, {:unreachable, :unknown_provider}}
    end
  end

  defp request(spec, key) do
    [
      method: spec.method,
      url: spec.url,
      headers: spec.headers ++ auth_header(spec.auth, key),
      receive_timeout: 15_000
    ]
    |> put_json(spec.json)
    |> Keyword.merge(config())
    |> Req.request()
    |> classify()
  end

  defp put_json(options, nil), do: options
  defp put_json(options, body), do: Keyword.put(options, :json, body)

  defp auth_header(:bearer, key), do: [{"authorization", "Bearer " <> key}]
  defp auth_header({:header, name}, key), do: [{name, key}]

  defp classify({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok
  defp classify({:ok, %Req.Response{status: status}}) when status in [401, 403], do: {:error, :rejected}
  defp classify({:ok, %Req.Response{status: status}}), do: {:error, {:unexpected, status}}
  defp classify({:error, reason}), do: {:error, {:unreachable, reason}}

  defp config, do: Application.get_env(:code_my_spec, __MODULE__, [])
end
