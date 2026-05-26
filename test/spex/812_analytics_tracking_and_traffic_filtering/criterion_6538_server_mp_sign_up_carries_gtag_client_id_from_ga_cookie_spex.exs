defmodule CodeMySpecSpex.Story812.Criterion6538Spex do
  @moduledoc """
  Story 812 — Analytics Tracking and Traffic Filtering.
  Criterion 6538 — Rule 5 (hybrid): Server MP sign_up carries the
  gtag client_id from the _ga cookie so it stitches to the browser
  session.

  Problem the old code had: `client_id` was always either `"anonymous"`
  (no user_id) or `"cms-<user_id>"` — neither of which stitches to the
  browser's GA4 session. GA4 treats each unique client_id as a distinct
  user, so a server MP hit with a wrong client_id creates an orphan
  session disconnected from all the browser pageviews and engagement.

  Fix required: the MP payload builder must read the `_ga` cookie from
  the request and parse it. The `_ga` cookie format is
  `GA1.1.<X>.<Y>` — the client_id is the `<X>.<Y>` tail. When the
  cookie is absent (pure CLI flow), fall back to a stable UUIDv4.

  Cassette-as-contract pattern:
  1. Seed a synthetic `_ga` cookie on the test conn before the
     registration form is submitted.
  2. Capture the MP POST in a cassette.
  3. Assert the captured sign_up payload carries a `client_id` matching
     the parsed `<X>.<Y>` tail of the seeded cookie — NOT `"anonymous"`
     and NOT the `cms-<user_id>` format.

  ## Recording

      GA_TEST_OAUTH_TOKEN=$(mix cms.ga_test_token | tail -n1) \\
        mix test test/spex/812_.../criterion_6538_*.exs --include ga_cassette_record

  Tagged `:ga_cassette_record` — skipped in normal runs until the cassette
  is recorded once. After recording, change `mode: :record` → `mode: :replay`
  and drop the tag.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import ReqCassette

  import CodeMySpecSpex.GaAssertions,
    only: [assert_cassette_contains_mp_event: 3, with_ga_plug: 2]

  @cassette_name "812_sign_up_ga_cookie_stitch"
  @cassette_dir "test/cassettes/analytics"

  # A synthetic _ga cookie value. Format: GA1.1.<X>.<Y>
  # The extracted client_id that the MP payload must carry is "<X>.<Y>".
  @ga_cookie_value "GA1.1.987654321.1700000000"
  @expected_client_id "987654321.1700000000"

  @moduletag :ga_cassette_record

  spex "Server MP sign_up carries gtag client_id from the _ga cookie" do
    scenario "sign_up MP POST uses the _ga cookie client_id, not anonymous or cms-<user_id>" do
      given_ "a fresh email and a conn seeded with a _ga cookie", context do
        email = "spex-812-stitch-#{System.unique_integer([:positive])}@codemyspec.test"

        # Seed the _ga cookie on the conn so the MP payload builder can
        # read it and extract the client_id.
        conn = Plug.Test.put_req_cookie(context.conn, "_ga", @ga_cookie_value)

        {:ok, context |> Map.put(:email, email) |> Map.put(:conn, conn)}
      end

      when_ "the visitor submits the magic-link registration form", context do
        with_cassette @cassette_name, cassette_opts(), fn plug ->
          with_ga_plug(plug, fn ->
            {:ok, lv, _html} = live(context.conn, "/users/register")

            lv
            |> form("#registration_form", user: %{email: context.email})
            |> render_submit()
          end)
        end

        {:ok, context}
      end

      then_ "the cassette captured sign_up with the _ga cookie's client_id", context do
        # The client_id in the MP payload must equal the <X>.<Y> tail of
        # the seeded _ga cookie — proving the MP builder parsed the cookie
        # rather than falling back to "anonymous" or "cms-<user_id>".
        assert_cassette_contains_mp_event(
          @cassette_name,
          "sign_up",
          expected_params: %{"method" => "magic_link"},
          cassette_dir: @cassette_dir
        )

        interactions = load_cassette_interactions(@cassette_name)
        sign_up_client_id = extract_event_client_id(interactions, "sign_up")

        assert sign_up_client_id == @expected_client_id,
               """
               Expected sign_up MP payload to carry client_id=#{@expected_client_id}
               (parsed from _ga cookie #{@ga_cookie_value}).

               Got: #{inspect(sign_up_client_id)}

               The MP payload builder must read the _ga cookie and parse
               the <X>.<Y> tail as the client_id. "anonymous" or
               "cms-<user_id>" are wrong — they don't stitch to the
               browser GA4 session.
               """

        {:ok, context}
      end

      then_ "the client_id is not anonymous and not the cms-<user_id> format", context do
        interactions = load_cassette_interactions(@cassette_name)
        sign_up_client_id = extract_event_client_id(interactions, "sign_up")

        refute sign_up_client_id == "anonymous",
               "sign_up MP client_id must not be \"anonymous\" — it must stitch to the browser session via the _ga cookie"

        refute is_binary(sign_up_client_id) and String.starts_with?(sign_up_client_id, "cms-"),
               "sign_up MP client_id must not use the old cms-<user_id> format — use the _ga cookie instead"

        {:ok, context}
      end
    end
  end

  # -- Helpers --

  defp cassette_opts do
    [
      cassette_dir: @cassette_dir,
      mode: :record,
      match_requests_on: [:method, :uri, :body],
      filter_request_headers: ["authorization", "cookie"],
      filter_response_headers: ["set-cookie"],
      filter_sensitive_data: [
        {~r/api_secret=[^&\s"]+/, "api_secret=<REDACTED>"}
      ]
    ]
  end

  defp load_cassette_interactions(cassette_name) do
    path = Path.join(@cassette_dir, cassette_name <> ".json")

    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"interactions" => interactions}} -> interactions
          _ -> []
        end

      _ ->
        []
    end
  end

  defp extract_event_client_id(interactions, event_name) do
    Enum.find_value(interactions, nil, fn interaction ->
      request = interaction["request"] || %{}

      if request["method"] == "POST" and
           String.starts_with?(request["uri"] || "", "https://www.google-analytics.com/mp/collect") do
        body = request["body_json"] || %{}
        events = body["events"] || []

        if Enum.any?(events, &(&1["name"] == event_name)) do
          body["client_id"]
        end
      end
    end)
  end
end
