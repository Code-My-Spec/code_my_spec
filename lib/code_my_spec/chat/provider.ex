defmodule CodeMySpec.Chat.Provider do
  @moduledoc """
  The model round-trip, behind a seam.

  Distinct from the `:chat_llm` seam in `Chat.Runner`, and the distinction is
  the point. `:chat_llm` replaces the *whole* live path with a script: it says
  what tool calls happen and what text follows, and the runner's own
  loop — history assembly, tool-call decoding, feeding results back, the round
  cap, error handling — never executes. That was fine while the live path was a
  stub, and it is why nine of story 995's criteria turned out to be
  unexercisable against the running app (issue `1d82eeea`): everything the
  spex proved was about a path production does not take.

  This seam replaces only the network call. Swap it and the live loop still
  runs for real, one provider reply at a time, which is what makes the loop
  itself testable without an API key.

      config :code_my_spec, :chat_provider, MyFakeProvider

  Implementations return whatever `ReqLLM.generate_text/3` returns, because
  callers read the reply with `ReqLLM.Response.tool_calls/1` and
  `ReqLLM.Response.text/1` and append `response.message` to the history.
  """

  @callback generate_text(
              model :: term(),
              messages :: [term()],
              opts :: keyword()
            ) :: {:ok, ReqLLM.Response.t()} | {:error, term()}

  @doc """
  Whether this provider can be called at all.

  Lives here rather than in the runner because "is there an API key" is a fact
  about the real provider and about nothing else — a fake has no key and is
  always ready, and a runner that checked for a key would refuse to use one.
  """
  @callback ready?() :: boolean()

  @doc "The configured provider, defaulting to the real one."
  @spec impl() :: module()
  def impl do
    Application.get_env(:code_my_spec, :chat_provider, __MODULE__.ReqLlm)
  end
end

defmodule CodeMySpec.Chat.Provider.ReqLlm do
  @moduledoc "The real round-trip. The only thing a fake provider replaces."

  @behaviour CodeMySpec.Chat.Provider

  @impl true
  def generate_text(model, messages, opts) do
    ReqLLM.generate_text(model, messages, opts)
  end

  @impl true
  def ready? do
    case ReqLLM.get_key(:anthropic_api_key) do
      key when is_binary(key) and key != "" -> true
      _ -> false
    end
  end
end
