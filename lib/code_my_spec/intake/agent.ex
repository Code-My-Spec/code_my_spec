defmodule CodeMySpec.Intake.Agent do
  @moduledoc """
  Runs one LLM turn outside the harness and the filesystem.

  Everything from a visitor's first message up to a real working copy coming
  up is the same mechanism underneath: send a prompt, require a tool call for
  the answer (`Alloy`'s `:until_tool`), extract it. What differs between call
  sites — the shaper's sign-in/tenancy question, the planner's plan, the
  story interview's questions and derived rules — is the prompt and the tool,
  not the mechanism. That is why this is a function, not another
  behaviour-plus-swappable-implementation pair alongside the ones each call
  site already has for testability (`Llm` vs `Scripted`/`Inferred`): those
  exist so surrounding code can get a fast, deterministic double without a
  cassette, which is a different concern from how a real call is made.

  No `Agents.Agent` row and no working copy — nothing here touches a
  filesystem, so there is nothing for the harness-side
  `CmsHarness.Agents.Engine` wrapper to add. The credential a call runs on is
  the only thing that changes once a real project exists to hand off to; the
  mechanism does not.
  """

  @default_model "anthropic:claude-sonnet-5"

  @doc """
  The model string's provider name — `"openai:gpt-5-mini"` becomes
  `"openai"`. A model string with no provider prefix is not a thing `ReqLLM`
  or `Alloy` accept here either, so the whole string is returned as given;
  callers resolving a provider module from it fall back to Anthropic in that
  case, same as a bare model name always has.
  """
  @spec provider_name(String.t()) :: String.t()
  def provider_name(model), do: model |> to_string() |> String.split(":", parts: 2) |> hd()

  @doc """
  Whether the model string's provider has a usable key configured.

  Named after the provider *in the model string*, not a fixed provider —
  looking up `:anthropic_api_key` unconditionally is the bug this project
  already shipped once (`Planner`'s original `configured_key?/0`): a
  deployment holding only an OpenAI key and an OpenAI model answered "no
  key" and fell through to an offline heuristic, silently, for every visitor.
  """
  @spec key_configured?(String.t()) :: boolean()
  def key_configured?(model) do
    case ReqLLM.get_key(:"#{provider_name(model)}_api_key") do
      key when is_binary(key) and key != "" -> true
      _ -> false
    end
  end

  @doc """
  Runs `prompt` against `tool`, which the model must call to answer.

  `tool` is an `Alloy.Tool` module or `Alloy.Tool.Inline` struct (see
  `Alloy.Tool.inline/1`) — the model is required to call it
  (`:until_tool`) before the loop completes, so the result is always a tool
  call's input rather than free text to parse.

  ## Options

    * `:model` — a `"provider:model"` string (default:
      `"anthropic:claude-sonnet-5"`)
    * `:max_turns` — loop iterations before giving up (default: `2` — one
      real attempt, one nudge if the model answered in prose instead)
    * `:req_options` — merged into the provider's own request options, after
      the default timeout. A test's cassette plug goes here.
    * `:provider_opts` — merged onto the provider config tuple, after
      `:api_key`/`:model`/`:req_options`. Anthropic and OpenAI take
      per-request tuning (temperature, and similar) as `extra_body`, not a
      top-level option — this is where a call site sets `extra_body: %{...}`.

  Returns the tool call's `input` map, or `{:error, reason}`.
  """
  @spec run(String.t(), module() | Alloy.Tool.Inline.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(prompt, tool, opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    tool_name = tool_name(tool)

    run_opts = [
      provider: provider(model, opts),
      tools: [tool],
      until_tool: tool_name,
      max_turns: Keyword.get(opts, :max_turns, 2)
    ]

    case Alloy.run(prompt, run_opts) do
      {:ok, result} -> extract(result, tool_name)
      {:error, result} -> {:error, result.error}
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
end
