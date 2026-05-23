defmodule CodeMySpecSpex.Story812.Criterion6501Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6501 — Rule 1: Known-bot / empty-signal request is
  filtered before dispatch.

  Telemetry-subscriber pattern for the negative assertion. A bot
  request hits the browser pipeline; we subscribe to the GA telemetry
  stream and `refute_receive` the dispatch. Proves the plug skipped
  the `:page_view` call entirely — no cassette needed because the
  contract is "this dispatch must NOT happen."

  Why not cassette: cassette absence is ambiguous (the cassette also
  doesn't get written if the test errored before any HTTP). Telemetry
  refute_receive is the contract: dispatch fired vs didn't.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecSpex.Fixtures

  @bot_ua "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

  setup do
    :ok = Fixtures.attach_ga_test_subscriber(self())
    on_exit(fn -> Fixtures.detach_ga_test_subscriber(self()) end)
    :ok
  end

  spex "Known-bot / empty-signal request is filtered before dispatch" do
    scenario "Googlebot UA hits the pipeline; no page_view dispatches" do
      given_ "a request with a known-bot User-Agent", context do
        conn = Plug.Conn.put_req_header(context.conn, "user-agent", @bot_ua)
        {:ok, Map.put(context, :conn, conn)}
      end

      when_ "the request hits the browser pipeline", context do
        Phoenix.ConnTest.get(context.conn, "/")
        {:ok, context}
      end

      then_ "no page_view telemetry event is dispatched", context do
        refute_receive {:ga_measurement_protocol,
                        %{events: [%{name: "page_view"} | _]}},
                       250

        {:ok, context}
      end
    end
  end
end
