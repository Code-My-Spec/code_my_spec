defmodule CodeMySpec.Agents.Phase.Model do
  @moduledoc """
  One model call, outside the harness and outside a working copy.

  Lifted out of `CodeMySpec.Intake.Agent`, which was the only thing in the
  application that knew how to call an LLM without a checkout to run it in. It
  carried its own provider table, its own key lookup and its own default model,
  none of which were about intake.

  Takes a list of tools rather than one, so a phase can be given several and
  still have a single call that ends its turn.

  ## Credentials

  Keys come from `ReqLLM.get_key/1`, named after the provider *in the model
  string* — a deployment holding only an OpenAI key and an OpenAI model answered
  "no key configured" when this looked up `:anthropic_api_key` unconditionally.

  `CodeMySpec.Agents.Credential.platform_credential/1` is the better answer and
  is deliberately not used here: it lives in the `CodeMySpec.Agents` boundary,
  which depends on `WorkingCopies`, `Sessions` and `Validation`, and pulling that
  in is the coupling this module exists to avoid. Worth revisiting if the
  platform spend cap needs to cover phases too.
  """

  @default_model "anthropic:claude-sonnet-5"

  # Two: one real attempt, and one nudge if the model answered in prose instead
  # of calling the tool.
  @default_max_turns 2

  @doc """
  The model string's provider name — `"openai:gpt-5-mini"` becomes `"openai"`.

  A model string with no provider prefix is not a thing `ReqLLM` names a key
  after, so callers resolving a provider from it fall back to Anthropic, same as
  a bare model name always has.
  """
  @spec provider_name(String.t() | atom()) :: String.t()
  def provider_name(model), do: model |> to_string() |> String.split(":", parts: 2) |> hd()

  @doc "Whether the model string's provider has a usable key configured."
  @spec key_configured?(String.t()) :: boolean()
  def key_configured?(model) do
    case ReqLLM.get_key(:"#{provider_name(model)}_api_key") do
      key when is_binary(key) and key != "" -> true
      _ -> false
    end
  end

  @doc """
  Runs `prompt` against `tools`, one of which the model must call to answer.

  ## Options

    * `:model` — a `"provider:model"` string (default: `#{@default_model}`)
    * `:until_tool` — the tool whose call ends the turn. Derived when `tools`
      holds exactly one; required otherwise.
    * `:max_turns` — default #{@default_max_turns}
    * `:provider_opts` — merged over the resolved provider options
    * `:req_options` — passed through to Req. Both providers take per-request
      tuning (`extra_body`, timeouts) here rather than as top-level options.

  Returns the tool call's `input` map.
  """
  @spec run(String.t(), [module() | Alloy.Tool.Inline.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(prompt, tools, opts \\ []) when is_binary(prompt) and is_list(tools) do
    model = Keyword.get(opts, :model, @default_model)
    until = until_tool(tools, opts)

    run_opts = [
      provider: provider(model, opts),
      tools: tools,
      until_tool: until,
      max_turns: Keyword.get(opts, :max_turns, @default_max_turns)
    ]

    case Alloy.run(prompt, run_opts) do
      {:ok, result} -> extract(result, until)
      {:error, result} -> {:error, result.error}
    end
  end

  # A single-tool phase names its own terminal tool; anything else has to say so.
  # Raising rather than guessing: picking one of several by position would be a
  # silent wrong answer, and this is a programmer error at the call site.
  defp until_tool([tool], opts), do: Keyword.get(opts, :until_tool, tool_name(tool))

  defp until_tool(tools, opts) do
    case Keyword.fetch(opts, :until_tool) do
      {:ok, name} ->
        name

      :error ->
        raise ArgumentError,
              "a phase offering #{length(tools)} tools must pass :until_tool — " <>
                "there is no safe default for which call ends the turn"
    end
  end

  defp tool_name(%Alloy.Tool.Inline{name: name}), do: name
  defp tool_name(module) when is_atom(module), do: module.name()

  defp extract(result, tool_name) do
    case Enum.find(result.tool_calls, &(&1.name == tool_name)) do
      nil -> {:error, :tool_not_called}
      %{input: input} -> {:ok, input}
    end
  end

  # `req_options`, not a top-level provider option — neither Alloy provider
  # accepts request-level settings like a timeout directly; both pass
  # `:req_options` straight through to Req, which is where they land.
  defp provider(model, opts) do
    {provider_module, model_name} = resolve_provider(model)

    req_options =
      Keyword.merge(
        [receive_timeout: to_timeout(second: 120)],
        Keyword.get(opts, :req_options, [])
      )

    base = [
      api_key: ReqLLM.get_key(:"#{provider_name(model)}_api_key"),
      model: model_name,
      req_options: req_options
    ]

    {provider_module, Keyword.merge(base, Keyword.get(opts, :provider_opts, []))}
  end

  defp resolve_provider("anthropic:" <> model_name), do: {Alloy.Provider.Anthropic, model_name}
  defp resolve_provider("openai:" <> model_name), do: {Alloy.Provider.OpenAI, model_name}
  # No prefix, or one neither provider owns: falls back to Anthropic with the
  # string as given, the same as the default model's own prefix.
  defp resolve_provider(model_name), do: {Alloy.Provider.Anthropic, model_name}

  @doc "The model used when a caller names none."
  @spec default_model() :: String.t()
  def default_model, do: @default_model
end
