defmodule CodeMySpec.ApiKeyCassetteHelpers do
  @moduledoc """
  Cassette wiring for `Integrations.Providers.ApiKey`, whose whole job is a
  request to a real provider.

  Stubbing it proves nothing: the question the module exists to answer is
  whether our headers and URL authenticate against Anthropic at all, and a
  `Req.Test` stub answers yes to any shape. So these run against a recording of
  the real exchange, replayed by default and re-recordable with a live key.

  ## The key never lands in the cassette

  `filter_request_headers` covers both auth shapes this module sends —
  `x-api-key` for Anthropic, `authorization` for Z.ai — because the credential
  is the one thing a committed recording must not carry. Replay sends a dummy
  in its place, which matches because the headers are not matched on.

  ## Re-recording

      API_KEY_RECORD=1 ANTHROPIC_API_KEY=sk-ant-… elixir -S mix test \\
        test/code_my_spec/integrations/providers/api_key_test.exs

  Delete the cassette you want refreshed first — `:record` replays on a match,
  so an existing file is returned rather than a new call being made, and the
  run then reports success having asked nobody anything.
  """

  @cassette_dir "test/cassettes/api_key"

  @doc "Replay by default; record when API_KEY_RECORD=1."
  def cassette_opts(extra \\ []) do
    Keyword.merge(
      [
        cassette_dir: @cassette_dir,
        mode: mode(),
        # One exchange per cassette, so nothing depends on ordering between
        # two requests that differ only by a header nobody records.
        match_requests_on: [:method, :uri],
        filter_request_headers: ["x-api-key", "authorization"],
        filter_response_headers: ["set-cookie"]
      ],
      extra
    )
  end

  @doc """
  Point `ApiKey`'s Req config at the cassette plug for the duration of `fun`.

  The same shape as `GoogleCassetteHelpers.with_plug/3`: production code reads
  its plug from config and stays unaware there is a test.
  """
  def with_plug(plug, fun) do
    module = CodeMySpec.Integrations.Providers.ApiKey
    original = Application.get_env(:code_my_spec, module, [])
    Application.put_env(:code_my_spec, module, Keyword.put(original, :plug, plug))

    try do
      fun.()
    after
      Application.put_env(:code_my_spec, module, original)
    end
  end

  @doc """
  A key that works. The real one while recording, a placeholder on replay —
  the header is filtered out of the cassette either way, so replay has nothing
  to match it against.
  """
  def live_key do
    case record?() do
      true -> System.fetch_env!("ANTHROPIC_API_KEY")
      false -> "replay-key"
    end
  end

  @doc """
  A key the provider will refuse.

  Derived from the live one by dropping its last character while recording, so
  what was sent is a real key with a real mistake in it — the ordinary way a
  paste goes wrong — rather than a string Anthropic would reject for being
  nothing like a key at all.
  """
  def broken_key do
    case record?() do
      true -> live_key() |> String.slice(0..-2//1)
      false -> "replay-key-broken"
    end
  end

  def record?, do: System.get_env("API_KEY_RECORD") in ~w(1 true yes)

  defp mode, do: if(record?(), do: :record, else: :replay)
end
