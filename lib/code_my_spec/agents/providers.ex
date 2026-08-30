defmodule CodeMySpec.Agents.Providers do
  @moduledoc """
  The providers an agent can be started on, and which credential kind each uses.

  One table, because the alternative is the thing rule 6 forbids: a `case` in
  the start path that knows one provider from another, which a third provider
  then has to be threaded through. Adding a provider here is adding a row.

  `provider` is Pi's own provider id — the key it uses in `auth.json` — so the
  name a caller passes is the name Pi reads. `integration_provider` is what our
  Integrations context calls the same thing, and the two differ often enough
  (`openai-codex` is a ChatGPT subscription, stored as `:openai`) that mapping
  them by convention rather than by table would be a silent mismatch.
  """

  # Anthropic is an api_key provider because that is the only way anyone can
  # connect it: no Assent strategy for it exists and never did, so the `:oauth`
  # it carried described a path that was never built. ChatGPT keeps `:oauth` —
  # it is a subscription rather than a key, and its device flow works.
  @providers %{
    "openai-codex" => %{integration_provider: :openai, kind: :oauth},
    "anthropic" => %{integration_provider: :anthropic, kind: :api_key},
    "zai" => %{integration_provider: :zai, kind: :api_key}
  }

  @spec known?(String.t()) :: boolean()
  def known?(provider), do: Map.has_key?(@providers, provider)

  @spec names() :: [String.t()]
  def names, do: @providers |> Map.keys() |> Enum.sort()

  @doc """
  The Integrations provider atom backing a Pi provider id.
  """
  @spec integration_provider(String.t()) :: {:ok, atom()} | {:error, :unknown_provider}
  def integration_provider(provider) do
    @providers
    |> Map.fetch(provider)
    |> take(:integration_provider)
  end

  @doc """
  Which of Pi's two credential kinds this provider stores.
  """
  @spec credential_kind(String.t()) :: :oauth | :api_key
  def credential_kind(provider), do: @providers |> Map.fetch!(provider) |> Map.fetch!(:kind)

  defp take({:ok, entry}, key), do: {:ok, Map.fetch!(entry, key)}
  defp take(:error, _key), do: {:error, :unknown_provider}
end
