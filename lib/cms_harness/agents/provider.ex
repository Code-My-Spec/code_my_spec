defmodule CmsHarness.Agents.Provider do
  @moduledoc """
  A provider name and a credential, as Alloy options.

  `:provider` is `{module, config}`, and the config half is the only place a
  provider's own settings survive. `Alloy.Agent.Config` keeps that half and
  drops everything else it does not recognise, so a flat `api_key:` beside the
  module is silently discarded and the first request raises about a missing key
  from inside the provider.

  The engine holds the loop; this decides who answers it. Kept apart because
  the two change for unrelated reasons — a new provider is a clause here and
  nothing in the engine, and the loop's supervision has nothing to say about
  which subscription is paying.

  ## The two cost models, which are not the two auth kinds

  It is tempting to read "API key" as metered and "OAuth" as flat-rate. That is
  wrong and the mistake is expensive when choosing what to run agents on:

    * `openai-codex` — the ChatGPT plan. Flat. `codex exec` handles the
      credential itself, so there is no key here at all. Reports **no token
      counts**, so anything metering agent spend is blind on this path.
    * `zai` — a coding plan, flat, reached with an API key over an
      OpenAI-compatible endpoint. Flat *and* counted.
    * `anthropic` — metered, per token, API key.

  Anthropic is deliberately here as an API key rather than a subscription:
  Anthropic does not permit subscription credentials in third-party harnesses,
  so there is no OAuth path to build even if we wanted one.
  """

  # The coding path, not the pay-as-you-go one. The same key works on both, and
  # only this one spends subscription quota rather than credits — so the URL is
  # what decides whether a month costs a flat fee or a bill.
  @zai_base "https://api.z.ai/api/coding/paas/v4"

  # What the GLM Coding Plan sells today. Older names still resolve — z.ai
  # routes them to 5.3 — so a stale default works while quietly never using what
  # was paid for, which is the failure worth naming rather than the one that
  # errors.
  @zai_model "glm-5.3"

  @type credential :: map()

  @doc """
  Alloy options for `provider`, or `{:error, :unknown_provider}`.

  `model` is passed rather than defaulted per provider: a default answers
  correctly right up until two callers want different models, and then quietly
  spends the wrong one's budget.
  """
  @spec options(String.t(), credential(), keyword()) :: {:ok, keyword()} | {:error, atom()}
  def options(provider, credential, opts \\ [])

  # `codex exec` reads its own `auth.json`; Alloy copies the one named here into
  # an isolated `CODEX_HOME` so an agent never inherits the machine's MCP or
  # plugin configuration — the same isolation the Pi config directory gave us,
  # and the reason a shared home is not an option on a multi-tenant box.
  def options("openai-codex", credential, opts) do
    {:ok,
     [
       provider:
         {Alloy.Provider.Codex,
          %{
            model: Keyword.get(opts, :model) || "gpt-5.4",
            auth_path: auth_path(credential),
            timeout_ms: Keyword.get(opts, :timeout_ms) || 180_000
          }}
     ]}
  end

  # `api_url` and `chat_path`, not `base_url`. `OpenAICompat` reads `:api_url`
  # and appends `/v1/chat/completions` by default; z.ai's coding path already
  # ends at `/v4/chat/completions`, so the default would ask for
  # `.../paas/v4/v1/chat/completions`.
  def options("zai", credential, opts) do
    with {:ok, api_key} <- fetch(credential, :api_key) do
      {:ok,
       [
         provider:
           {Alloy.Provider.OpenAICompat,
            %{
              # `||`, not a `Keyword.get/3` default: the caller passes every
              # option it knows about and most of them are nil, and a stored
              # nil satisfies `Keyword.get/3` — so the default would be skipped
              # and the request would go to `nil/chat/completions`.
              api_url: Keyword.get(opts, :base_url) || @zai_base,
              chat_path: "/chat/completions",
              api_key: api_key,
              model: Keyword.get(opts, :model) || @zai_model
            }}
       ]}
    end
  end

  def options("anthropic", credential, opts) do
    with {:ok, api_key} <- fetch(credential, :api_key) do
      {:ok,
       [
         provider:
           {Alloy.Provider.Anthropic,
            %{
              api_key: api_key,
              model: Keyword.get(opts, :model) || "claude-sonnet-5"
            }}
       ]}
    end
  end

  def options(_provider, _credential, _opts), do: {:error, :unknown_provider}

  @doc "Every provider this harness can run an agent on."
  @spec names() :: [String.t()]
  def names, do: ["anthropic", "openai-codex", "zai"]

  # The credential's own auth file, or this machine's codex login.
  #
  # The fallback is an interim and a known compromise. Minting a per-tenant
  # `auth.json` needs an `id_token` our openai integration does not store — the
  # open question on story 956 — so until it does, a codex agent runs on
  # whatever `codex` is logged in as here. Right on a single-tenant box, wrong
  # on a shared one, and deliberate either way: failing instead would report a
  # missing credential for one that is connected and working.
  defp auth_path(credential) do
    case fetch(credential, :auth_path) do
      {:ok, path} -> path
      {:error, _} -> Path.expand("~/.codex/auth.json")
    end
  end

  # Named rather than pattern-matched into the clause head so the failure says
  # which piece was missing. A credential that arrived without its key and one
  # for a provider we do not know are different problems for whoever reads it.
  defp fetch(credential, key) do
    case Map.get(credential, key) || Map.get(credential, to_string(key)) do
      nil -> {:error, :"credential_missing_#{key}"}
      value -> {:ok, value}
    end
  end
end
