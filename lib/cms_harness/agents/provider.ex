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

  # `req_options` reaches Req itself, in `complete/3` and `stream/4` alike. It
  # exists so a recorder can sit in front of the provider's HTTP client and
  # capture a turn this engine actually ran — a recording made by calling Alloy
  # directly would be a recording of Alloy.
  #
  # Only on the two providers that speak HTTP. `codex exec` is a subprocess, so
  # there is no Req client to put anything in front of, and accepting the option
  # there would look like it worked.

  # `codex exec` runs against **this machine's own Codex login**, in this
  # machine's own `CODEX_HOME`. Nothing is minted, copied, or managed.
  #
  # It used to be handed an `auth.json` to copy into an isolated home, and that
  # is unworkable rather than merely awkward. A ChatGPT refresh token is
  # single-use: the CLI rotates it on startup and every other copy dies. With
  # four agents each holding a private copy of one token, the first to start
  # invalidated the rest — `codex_auth/1` in `CmsHarness.Agents` predicted this
  # in as many words ("rotates the refresh token and invalidates every other
  # copy of it, including the one in our database") and it happened anyway,
  # because the prediction was about a race no amount of care in one writer can
  # win.
  #
  # Measured 2026-09-08: every agent on Broken Oaths failing with "your access
  # token could not be refreshed because your refresh token was already used",
  # intermittently since 09-03 — and John's own `codex` CLI logged out along
  # with them, because the token the agents burned was his.
  #
  # John's call, and it is the only posture that is also right on terms of
  # service: an agent here is the user's own machine running the user's own
  # Codex login, exactly as if they had typed `codex` themselves. We do not hold
  # their subscription, so we cannot leak it, rotate it, or get them banned for
  # how we used it.
  #
  # The cost is real and accepted: an agent inherits this machine's Codex
  # configuration — its MCP servers and plugins — where an isolated home gave it
  # none. That is wrong on a shared box, and a shared box is what this decision
  # rules out.
  #
  # No model unless one was asked for, and that is the opposite of the other two
  # clauses on purpose. A ChatGPT plan decides which models it serves, and
  # naming one here is a guess about somebody else's subscription: this shipped
  # defaulting to `gpt-5.4`, and every codex agent on a ChatGPT account failed
  # its first turn with *"The 'gpt-5.4' model is not supported when using Codex
  # with a ChatGPT account"*. Omitting the flag makes `codex exec` use whatever
  # that account actually has, which is always a valid answer and never goes
  # stale.
  def options("openai-codex", credential, opts) do
    {:ok,
     [
       provider:
         {Alloy.Provider.Codex,
          %{
            model: Keyword.get(opts, :model),
            codex_home: codex_home(credential),
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
              model: Keyword.get(opts, :model) || @zai_model,
              req_options: Keyword.get(opts, :req_options) || []
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
              model: Keyword.get(opts, :model) || "claude-sonnet-5",
              req_options: Keyword.get(opts, :req_options) || []
            }}
       ]}
    end
  end

  # The subscription running on this machine, not a credential from the
  # server: `claude` handles its own OAuth login state, exactly like `codex
  # exec`, so there is nothing here to fetch from `credential`.
  #
  # `workdir: working_copy`, not the provider's own default of a fresh temp
  # directory per call. `Alloy.Provider.ClaudeCode` resumes the underlying
  # `claude` session turn to turn (`--resume`) once one exists in
  # `provider_state`, and that only buys back its prompt-cache cost — not
  # just correct recall — when every call in one agent's lifetime runs from
  # the same directory (verified against the real CLI: resuming from a
  # different directory still recalls the conversation but never hits the
  # cache). An agent already has exactly one working copy for its whole
  # life, so passing it here costs nothing and is the difference between
  # `--resume` actually paying for itself and being a no-op.
  def options("claude-code", _credential, opts) do
    {:ok,
     [
       provider:
         {Alloy.Provider.ClaudeCode,
          %{
            model: Keyword.get(opts, :model) || "claude-sonnet-5",
            workdir: Keyword.get(opts, :working_copy),
            timeout_ms: Keyword.get(opts, :timeout_ms) || 180_000
          }}
     ]}
  end

  def options(_provider, _credential, _opts), do: {:error, :unknown_provider}

  @doc "Every provider this harness can run an agent on."
  @spec names() :: [String.t()]
  def names, do: ["anthropic", "openai-codex", "zai", "claude-code"]

  # This machine's Codex home, which the CLI already owns.
  #
  # `Alloy.Provider.Codex` uses a `:codex_home` as given and only falls back to
  # building an isolated one — and copying an `auth.json` into it — when none is
  # named. Naming it is what keeps one login in one place with one writer
  # rotating it.
  #
  # A credential may still name its own, for a deployment that has somewhere
  # better to point. What it may no longer do is hand over a token for us to
  # write down.
  defp codex_home(credential) do
    case fetch(credential, :codex_home) do
      {:ok, path} -> Path.expand(path)
      {:error, _} -> Path.expand("~/.codex")
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
