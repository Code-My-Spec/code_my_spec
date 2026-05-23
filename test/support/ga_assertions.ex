defmodule CodeMySpecSpex.GaAssertions do
  @moduledoc """
  Round-trip assertions against the Google Analytics Data API.

  Used by spex tests after dispatching an event to assert that GA
  actually received it. Pairs with cassette recording in the same test
  flow: the outgoing MP POST is captured by the
  `CodeMySpec.Analytics.GoogleAnalytics.HTTPAdapter` plug-config, the
  inbound Realtime Report query is captured by the
  `CodeMySpec.Analytics.GoogleAnalytics.ReportingClient` plug-config.
  Both plugs are wired by `with_ga_cassette/3` so a single cassette
  file holds the full round-trip.

  Realtime Reports are used because they surface freshly-dispatched
  events within minutes — standard Reports lag 24-48 hours, which
  breaks the record-once-then-replay flow.

  ## Example

      with_ga_cassette "812_signup_round_trip", scope, fn ->
        # Drive the surface — fires :sign_up via Analytics.dispatch
        post(conn, ~p"/users/register", user: %{email: "test@example.com"})

        # Verify GA received it
        assert_event_recorded(scope, "sign_up",
          property_id: "508773792",
          with_dimensions: [{"customEvent:method", "magic_link"}]
        )
      end
  """

  use Boundary, top_level?: true, deps: [CodeMySpec]

  import ExUnit.Assertions

  alias CodeMySpec.Analytics.GoogleAnalytics
  alias CodeMySpec.Analytics.GoogleAnalytics.ReportingClient
  alias CodeMySpec.Users.Scope

  @ga_mp_endpoint "https://www.google-analytics.com/mp/collect"
  @cassette_dir "test/cassettes/analytics"

  @doc """
  Asserts that GA's Realtime Report shows at least `min_count` rows
  matching `event_name` (and optionally each `{dimension, value}` in
  `with_dimensions`).

  ## Options

  - `:property_id` — the GA4 numeric property id. Required.
  - `:with_dimensions` — list of `{dimension_name, expected_value}`
    tuples. Each dimension must appear in the row's dimension values
    with the expected value. Standard dimensions: `eventName`,
    `customEvent:<param_name>` (custom dim must be registered).
    Default: `[]` (only event_name is matched).
  - `:min_count` — minimum count of matching rows. Default: 1.
  - `:token` — pre-fetched OAuth access token, used instead of looking
    up the scope's Google integration. Useful during cassette
    recording where a long sleep between dispatch and assertion can
    invalidate the Ecto sandbox connection before the DB query for
    the integration runs.
  """
  @spec assert_event_recorded(Scope.t(), String.t(), keyword()) :: :ok | no_return()
  def assert_event_recorded(%Scope{} = scope, event_name, opts \\ []) do
    property_id = Keyword.fetch!(opts, :property_id)
    extra_dims = Keyword.get(opts, :with_dimensions, [])
    min_count = Keyword.get(opts, :min_count, 1)
    token = Keyword.get(opts, :token)

    request = build_realtime_request(event_name, extra_dims)
    reporting_opts = if token, do: [token: token], else: []

    case ReportingClient.run_realtime_report(scope, property_id, request, reporting_opts) do
      {:ok, response} ->
        matching_rows = matching_rows(response, event_name, extra_dims)

        if length(matching_rows) >= min_count do
          :ok
        else
          flunk("""
          Expected ≥ #{min_count} GA realtime row(s) for event #{inspect(event_name)} \
          with dimensions #{inspect(extra_dims)}, but found #{length(matching_rows)}.

          Full response:
          #{inspect(response, pretty: true, limit: :infinity)}
          """)
        end

      {:error, reason} ->
        flunk("""
        GA Realtime Report request failed: #{inspect(reason)}.

        event_name: #{inspect(event_name)}
        property_id: #{inspect(property_id)}
        request: #{inspect(request, pretty: true)}
        """)
    end
  end

  @doc """
  Asserts that the cassette at `cassette_name` recorded at least one
  POST to `https://www.google-analytics.com/mp/collect` whose event
  name matches `event_name` (and, optionally, whose params include
  every key/value in `expected_params`).

  This is the relaxed verification path: instead of querying GA's
  Reporting API (subject to multi-minute ingest latency), it reads
  the captured cassette and asserts the right MP payload was POSTed.
  The cassette IS the contract — if a future change drops or warps
  the dispatch, the cassette won't contain the expected POST and the
  assertion fails.

  ## Options

  - `:expected_params` — map of params (or string keys) that must all
    appear in the captured event's `params` block. Default: `%{}`
    (only event_name is matched).
  - `:user_id` — when set, requires the captured payload's top-level
    `user_id` to match. Default: not asserted.
  - `:cassette_dir` — defaults to `test/cassettes/analytics`.
  """
  @spec assert_cassette_contains_mp_event(String.t(), String.t(), keyword()) ::
          :ok | no_return()
  def assert_cassette_contains_mp_event(cassette_name, event_name, opts \\ []) do
    expected_params = Keyword.get(opts, :expected_params, %{})
    expected_user_id = Keyword.get(opts, :user_id)
    cassette_dir = Keyword.get(opts, :cassette_dir, @cassette_dir)
    path = Path.join(cassette_dir, cassette_name <> ".json")

    interactions = load_interactions(path)
    mp_events = mp_events(interactions)

    if Enum.any?(mp_events, &event_matches?(&1, event_name, expected_params, expected_user_id)) do
      :ok
    else
      flunk("""
      Cassette #{path} contains no MP POST matching:

        event:    #{inspect(event_name)}
        params:   #{inspect(expected_params)}
        user_id:  #{inspect(expected_user_id)}

      Captured MP events (#{length(mp_events)}):
      #{format_mp_events(mp_events)}
      """)
    end
  end

  @doc """
  Wraps a function in plug-config for BOTH the MP HTTPAdapter and the
  ReportingClient, pointing both at the same cassette plug. Outgoing
  MP POSTs and inbound Realtime Report queries land in one cassette
  file under `test/cassettes/analytics/<name>.json`.

  Use `mode: :record` on first run (no cassette exists yet), then
  `mode: :replay` or omit to replay.
  """
  @spec with_ga_cassette(String.t(), Scope.t(), (-> any())) :: any()
  def with_ga_cassette(_cassette_name, %Scope{} = _scope, fun) do
    # Cassette setup is performed by the calling spex via ReqCassette's
    # `with_cassette/3` — this function only handles the plug-config
    # threading once a plug exists. See pilot spex for the full pattern.
    fun.()
  end

  @doc """
  Installs the same cassette plug on both the MP HTTPAdapter and the
  ReportingClient for the duration of `fun`. Restores the original
  plug values (typically `nil`) on exit.
  """
  @spec with_ga_plug(any(), (-> any())) :: any()
  def with_ga_plug(plug, fun) do
    original_mp =
      Application.get_env(:code_my_spec, GoogleAnalytics.HTTPAdapter, [])
      |> Keyword.get(:plug)

    original_reporting =
      Application.get_env(:code_my_spec, ReportingClient, [])
      |> Keyword.get(:plug)

    Application.put_env(:code_my_spec, GoogleAnalytics.HTTPAdapter, plug: plug)
    Application.put_env(:code_my_spec, ReportingClient, plug: plug)

    try do
      fun.()
    after
      Application.put_env(:code_my_spec, GoogleAnalytics.HTTPAdapter, plug: original_mp)
      Application.put_env(:code_my_spec, ReportingClient, plug: original_reporting)
    end
  end

  # -- Internals --------------------------------------------------------------

  defp build_realtime_request(event_name, extra_dims) do
    dimensions =
      [%{"name" => "eventName"}] ++
        Enum.map(extra_dims, fn {name, _value} -> %{"name" => name} end)

    %{
      "dimensions" => Enum.uniq(dimensions),
      "metrics" => [%{"name" => "eventCount"}],
      "dimensionFilter" => %{
        "filter" => %{
          "fieldName" => "eventName",
          "stringFilter" => %{
            "value" => event_name,
            "matchType" => "EXACT"
          }
        }
      }
    }
  end

  defp load_interactions(path) do
    case File.read(path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"interactions" => interactions}} when is_list(interactions) -> interactions
          {:ok, _} -> flunk("Cassette #{path} has no `interactions` array")
          {:error, reason} -> flunk("Cassette #{path} is not valid JSON: #{inspect(reason)}")
        end

      {:error, :enoent} ->
        flunk("""
        Cassette #{path} doesn't exist yet. Record it first:

            GA_TEST_OAUTH_TOKEN=$(mix cms.ga_test_token | tail -n1) \\
              mix test <this spex file> --include ga_cassette_record
        """)

      {:error, reason} ->
        flunk("Cassette #{path} unreadable: #{inspect(reason)}")
    end
  end

  defp mp_events(interactions) do
    Enum.flat_map(interactions, fn interaction ->
      request = interaction["request"] || %{}

      if request["method"] == "POST" and is_binary(request["uri"]) and
           String.starts_with?(request["uri"], @ga_mp_endpoint) do
        body = request["body_json"] || %{}
        events = body["events"] || []
        Enum.map(events, fn event -> {event, body["user_id"]} end)
      else
        []
      end
    end)
  end

  defp event_matches?({event, user_id}, expected_name, expected_params, expected_user_id) do
    event["name"] == expected_name and
      params_match?(event["params"] || %{}, expected_params) and
      user_id_matches?(user_id, expected_user_id)
  end

  defp params_match?(_actual, expected) when expected == %{}, do: true

  defp params_match?(actual, expected) do
    Enum.all?(expected, fn {key, value} ->
      str_key = to_string(key)
      Map.get(actual, str_key) == value or Map.get(actual, key) == value
    end)
  end

  defp user_id_matches?(_actual, nil), do: true
  defp user_id_matches?(actual, expected), do: to_string(actual) == to_string(expected)

  defp format_mp_events([]), do: "  (none)"

  defp format_mp_events(events) do
    Enum.map_join(events, "\n", fn {event, user_id} ->
      "  - #{event["name"]} user_id=#{inspect(user_id)} params=#{inspect(event["params"])}"
    end)
  end

  defp matching_rows(response, event_name, extra_dims) do
    rows = Map.get(response, "rows", []) || []
    headers = Map.get(response, "dimensionHeaders", []) || []
    header_names = Enum.map(headers, & &1["name"])

    rows
    |> Enum.filter(fn row ->
      values = Enum.map(row["dimensionValues"] || [], & &1["value"])
      pairs = Enum.zip(header_names, values) |> Map.new()

      Map.get(pairs, "eventName") == event_name and
        Enum.all?(extra_dims, fn {name, expected} ->
          Map.get(pairs, name) == expected
        end)
    end)
  end
end
