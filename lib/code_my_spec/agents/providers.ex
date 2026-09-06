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
  #
  # `claude-code` is a third kind, `:local`, and it is not like the other two.
  # Every other row names an Integration the *account* connects, and
  # `Credential` mints whatever token that Integration holds onto the machine
  # running the agent. There is no such Integration here — `claude-code` runs
  # on whichever `claude` CLI login already exists on the harness machine
  # itself, and the server never sees, stores, or mints anything for it.
  #
  # That has two consequences nothing here enforces yet:
  #
  # 1. **No per-account isolation.** `Credential.fetch/2` answers `{:ok, %{}}`
  #    for every account unconditionally (see below) — there is no connected/
  #    not-connected distinction to check. If two accounts ever share a
  #    harness machine, both get whichever Claude subscription is logged in
  #    there. Fine for a single operator; not fine the moment this is a
  #    multi-tenant deployment with harnesses that are not each account's own
  #    machine. TODO: gate this to specific accounts (an allowlist, a feature
  #    flag — undecided) before it is offered more broadly than that.
  #
  # 2. **Unclear ToS standing.** Running `claude` unattended, in a loop, as a
  #    structured-completion backend for another product is a different usage
  #    pattern from interactive coding sessions, and whether Anthropic's
  #    consumer/subscription terms permit it for this kind of always-on,
  #    automated, multi-turn use has not been checked. TODO: get an actual
  #    answer on this before recommending anyone but the operator running
  #    their own subscription rely on it. Until then, treat it as
  #    experimental / at-your-own-risk — including the risk of the
  #    underlying Claude account itself being actioned.
  @providers %{
    "openai-codex" => %{integration_provider: :openai, kind: :oauth},
    "anthropic" => %{integration_provider: :anthropic, kind: :api_key},
    "zai" => %{integration_provider: :zai, kind: :api_key},
    "claude-code" => %{integration_provider: nil, kind: :local}
  }

  @spec known?(String.t()) :: boolean()
  def known?(provider), do: Map.has_key?(@providers, provider)

  @spec names() :: [String.t()]
  def names, do: @providers |> Map.keys() |> Enum.sort()

  @doc """
  The Integrations provider atom backing a Pi provider id.

  `nil` for a `:local` provider — see the moduledoc. There is no Integration
  to look up, and no caller should be asking this for one; `Credential`
  short-circuits on `kind/1` before it ever reaches this function for those.
  """
  @spec integration_provider(String.t()) :: {:ok, atom() | nil} | {:error, :unknown_provider}
  def integration_provider(provider) do
    @providers
    |> Map.fetch(provider)
    |> take(:integration_provider)
  end

  @doc """
  Which of Pi's two credential kinds this provider stores.

  Raises for a `:local` provider — there is no Pi credential shape for one,
  by design. Callers that need to branch on `:local` first (`Credential`)
  use `kind/1` instead, which answers for every known provider without
  raising.
  """
  @spec credential_kind(String.t()) :: :oauth | :api_key
  def credential_kind(provider) do
    case @providers |> Map.fetch!(provider) |> Map.fetch!(:kind) do
      kind when kind in [:oauth, :api_key] -> kind
    end
  end

  @doc """
  Every credential kind this provider might answer, `:local` included.

  The safe, non-raising counterpart `Credential` branches on before deciding
  whether there is a Pi credential to build at all.
  """
  @spec kind(String.t()) :: {:ok, :oauth | :api_key | :local} | {:error, :unknown_provider}
  def kind(provider) do
    @providers |> Map.fetch(provider) |> take(:kind)
  end

  defp take({:ok, entry}, key), do: {:ok, Map.fetch!(entry, key)}
  defp take(:error, _key), do: {:error, :unknown_provider}
end
