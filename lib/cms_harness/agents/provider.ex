defmodule CmsHarness.Agents.Provider do
  @moduledoc """
  A provider name and a credential, as Alloy options.

  `:provider` is `{module, config}`; provider settings must live in the config
  half, because `Alloy.Agent.Config` silently drops unrecognised flat options.

  The engine holds the loop; this decides who answers it.
  See knowledge/harness, "Providers".
  """

  # The coding-plan path: the same key works on pay-as-you-go, but only this URL
  # spends subscription quota.
  @zai_base "https://api.z.ai/api/coding/paas/v4"

  # What the GLM Coding Plan sells; older names silently resolve to an older
  # model, so keep this current.
  @zai_model "glm-5.3"

  # DeepInfra's OpenAI-compatible endpoint. The model is a default only; an
  # agent's own model setting overrides it.
  @deepinfra_base "https://api.deepinfra.com/v1/openai"
  @deepinfra_model "deepseek-ai/DeepSeek-V3.1"

  # One budget for both CLI providers: a turn runs whole test files and spex.
  @cli_exec_timeout_ms :timer.minutes(10)

  # `codex exec` refuses prompts over 1,048,576 characters; Alloy's default
  # 200k-token budget (at ~4 chars/token) lets a transcript pass that before
  # compacting. 160k compacts near 575k characters, leaving room for the rest.
  @codex_max_tokens 160_000

  @type credential :: map()

  @doc """
  Alloy options for `provider`, or `{:error, :unknown_provider}`.

  `opts[:model]` overrides each provider's default; `openai-codex` has none.
  """
  @spec options(String.t(), credential(), keyword()) :: {:ok, keyword()} | {:error, atom()}
  def options(provider, credential, opts \\ [])

  # `req_options` reaches Req on the HTTP providers only (for recordings);
  # the CLI providers are subprocesses and do not accept it.

  # `codex exec` runs on this machine's own Codex login and `CODEX_HOME`;
  # nothing is minted or copied. No default model: the ChatGPT plan decides
  # which models it serves. `workdir` is the working copy (unset, it runs in
  # Alloy's temp dir). `ignore_user_config`: borrow the login, not the owner's
  # plugins, MCP servers and approvers. See knowledge/harness, "Providers".
  def options("openai-codex", credential, opts) do
    {:ok,
     [
       provider:
         {Alloy.Provider.Codex,
          %{
            model: Keyword.get(opts, :model),
            workdir: Keyword.get(opts, :working_copy),
            codex_home: codex_home(credential),
            ignore_user_config: true,
            timeout_ms: Keyword.get(opts, :timeout_ms) || @cli_exec_timeout_ms
          }
          |> with_command_runner()},
       max_tokens: @codex_max_tokens
     ]}
  end

  # `chat_path` overrides `OpenAICompat`'s default `/v1/chat/completions`;
  # z.ai's base already ends at `/v4`.
  def options("zai", credential, opts) do
    with {:ok, api_key} <- fetch(credential, :api_key) do
      {:ok,
       [
         provider:
           {Alloy.Provider.OpenAICompat,
            %{
              # `||`, not a `Keyword.get/3` default: callers pass explicit nils.
              api_url: Keyword.get(opts, :base_url) || @zai_base,
              chat_path: "/chat/completions",
              api_key: api_key,
              model: Keyword.get(opts, :model) || @zai_model,
              req_options: Keyword.get(opts, :req_options) || []
            }}
       ]}
    end
  end

  def options("deepinfra", credential, opts) do
    with {:ok, api_key} <- fetch(credential, :api_key) do
      {:ok,
       [
         provider:
           {Alloy.Provider.OpenAICompat,
            %{
              api_url: Keyword.get(opts, :base_url) || @deepinfra_base,
              chat_path: "/chat/completions",
              api_key: api_key,
              model: Keyword.get(opts, :model) || @deepinfra_model,
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

  # This machine's own `claude` login; no credential is fetched. `workdir` is
  # the working copy so `--resume` hits the prompt cache (it only does from the
  # same directory). The timeout is wall clock on the whole call, and must
  # outlast a silent auto-compaction. See knowledge/harness, "Providers".
  def options("claude-code", _credential, opts) do
    {:ok,
     [
       provider:
         {Alloy.Provider.ClaudeCode,
          %{
            model: Keyword.get(opts, :model) || "claude-sonnet-5",
            workdir: Keyword.get(opts, :working_copy),
            timeout_ms: Keyword.get(opts, :timeout_ms) || @cli_exec_timeout_ms
          }
          |> with_command_runner()}
     ]}
  end

  def options(_provider, _credential, _opts), do: {:error, :unknown_provider}

  # Replaces the real `codex`/`claude` CLI, from config. Set only in test,
  # where it is pinned to a recording so no test runs a live CLI.
  defp with_command_runner(config) do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:command_runner] do
      {module, function} ->
        Map.put(config, :command_runner, &apply(module, function, [&1, &2, &3]))

      nil ->
        config
    end
  end

  @doc "Every provider this harness can run an agent on."
  @spec names() :: [String.t()]
  def names, do: ["anthropic", "openai-codex", "zai", "deepinfra", "claude-code"]

  # Always named, so `Alloy.Provider.Codex` never builds an isolated home and
  # copies a token into it. A credential may name a different home.
  defp codex_home(credential) do
    case fetch(credential, :codex_home) do
      {:ok, path} -> Path.expand(path)
      {:error, _} -> Path.expand("~/.codex")
    end
  end

  # Not matched in the clause head, so the error names the missing key.
  defp fetch(credential, key) do
    case Map.get(credential, key) || Map.get(credential, to_string(key)) do
      nil -> {:error, :"credential_missing_#{key}"}
      value -> {:ok, value}
    end
  end
end
