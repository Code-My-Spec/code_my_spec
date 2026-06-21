defmodule CodeMySpec.GoogleCassetteHelpers do
  @moduledoc """
  Shared helpers for the cassette-backed Search Console / Analytics Req
  client tests.

  Tests run in `:replay` mode against the committed fixtures under
  `test/cassettes/google` (authored to mirror the real Google API response
  shapes). To re-record against the live APIs, set `GOOGLE_RECORD=1` plus a
  `GOOGLE_ACCESS_TOKEN` (or `GOOGLE_REFRESH_TOKEN`) with the Search Console
  (`webmasters`) / Analytics (`analytics.readonly`) scopes, delete the
  cassette you want to refresh, and run the test.
  """

  @cassette_dir "test/cassettes/google"

  @doc "ReqCassette opts: replay-only by default; record when GOOGLE_RECORD=1."
  def cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: mode(),
      # Sequential replay so tools that make several same-URL requests
      # (e.g. get_performance_overview, compare_search_periods) get the
      # interactions back in the order they were authored.
      sequential: true,
      match_requests_on: [:method, :uri],
      filter_request_headers: ["authorization"],
      filter_response_headers: ["set-cookie"]
    ]
  end

  @doc """
  Injects the ReqCassette `plug` into the given client module's config for
  the duration of `fun`, so its `Req` calls are recorded/replayed.
  """
  def with_plug(client_module, plug, fun) do
    original = Application.get_env(:code_my_spec, client_module, [])
    Application.put_env(:code_my_spec, client_module, Keyword.put(original, :plug, plug))

    try do
      fun.()
    after
      Application.put_env(:code_my_spec, client_module, original)
    end
  end

  @doc """
  The bearer token to use. A static dummy in replay mode (it's filtered out
  of cassettes anyway); a real scoped token when recording.
  """
  def token do
    if record?() do
      CodeMySpec.GoogleAuthHelper.get_token()
    else
      "replay-token"
    end
  end

  defp mode, do: if(record?(), do: :record, else: :replay)

  defp record?, do: System.get_env("GOOGLE_RECORD") in ~w(1 true yes)
end
