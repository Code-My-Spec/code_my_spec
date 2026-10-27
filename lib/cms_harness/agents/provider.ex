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
  @spec options(String.t(), credential(), keyword()) ::
          {:ok, keyword()} | {:error, atom() | {:model_not_available, String.t()}}
  def options(provider, credential, opts \\ [])

  # `req_options` reaches Req on the HTTP providers only (for recordings);
  # the CLI providers are subprocesses and do not accept it.

  # `codex exec` runs on this machine's own Codex login and `CODEX_HOME`;
  # nothing is minted or copied, and Alloy runs it with `--ignore-user-config`
  # (the login, not the owner's plugins, MCP servers and approvers). No default
  # model: the ChatGPT plan decides which models it serves. `workdir` is the
  # working copy, which `persist_session` requires. `persist_session` resumes
  # Codex's own thread instead of resending the transcript every turn; the
  # engine changes `:session_generation` after a turn that failed or was
  # stopped. Alloy turns off Codex's own shell and other native tools: the
  # outer loop's tools run commands, and left on, Codex answered for them
  # inside its read-only sandbox and the loop never saw a tool call. The
  # override here drops the permissions instructions: Alloy runs Codex read-only, and Codex told the
  # model "`sandbox_mode` is `read-only`: The sandbox only permits reading
  # files", so it refused to ask for the outer Edit/Write tools that do the
  # writing, scoped to the checkout. Codex's own process stays read-only. See
  # knowledge/harness, "Providers".
  def options("openai-codex", credential, opts) do
    config =
      %{
        model: Keyword.get(opts, :model),
        workdir: Keyword.get(opts, :working_copy),
        codex_home: codex_home(credential),
        persist_session: true,
        # Codex's own tools are switched off in Alloy itself (its provider's
        # native-tools list); this drops only the permissions instructions.
        config_overrides: ["include_permissions_instructions=false"],
        timeout_ms: Keyword.get(opts, :timeout_ms) || @cli_exec_timeout_ms
      }
      |> with_command_runner()

    with :ok <- codex_model_available(config) do
      {:ok, [provider: {CmsHarness.Agents.CodexWithTools, config}, max_tokens: @codex_max_tokens]}
    end
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
  # the working copy, one stable directory per conversation. The timeout is how
  # long the CLI may go quiet, and must outlast a silent auto-compaction. See knowledge/harness, "Providers".
  def options("claude-code", _credential, opts) do
    {:ok,
     [
       provider:
         {AlloyClaudeCode,
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

  # A model the login cannot use fails every turn with a 400 ("… is not
  # supported when using Codex with a ChatGPT account"), so the agent is refused
  # at start instead. The Codex CLI caches the models the login serves in its
  # home; with no cache nothing is known and the start goes ahead. Not against a
  # recorded CLI, which has no login.
  defp codex_model_available(%{command_runner: _recorded}), do: :ok
  defp codex_model_available(%{model: nil}), do: :ok

  defp codex_model_available(%{model: model, codex_home: home}) do
    case served_models(Path.join(home, "models_cache.json")) do
      [_ | _] = served ->
        if model in served do
          :ok
        else
          {:error,
           {:model_not_available,
            "Codex at #{home} does not serve the model #{inspect(model)} to this login. " <>
              "It serves: #{Enum.join(served, ", ")}. Set the agent's model to one of those, " <>
              "or leave it unset for the login's default."}}
        end

      [] ->
        :ok
    end
  end

  defp served_models(cache) do
    with {:ok, json} <- File.read(cache),
         {:ok, %{"models" => models}} when is_list(models) <- Jason.decode(json) do
      for %{"slug" => slug} when is_binary(slug) <- models, do: slug
    else
      _ -> []
    end
  end

  # Always named rather than inherited from this BEAM's environment. A
  # credential may name a different home.
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
