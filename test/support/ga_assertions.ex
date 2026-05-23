defmodule CodeMySpecSpex.GaAssertions do
  @moduledoc """
  Cassette-as-contract assertions for the GA Measurement Protocol path.

  Used by spex tests after dispatching events. The pattern:

  1. Drive the surface (controller / LiveView / Wallaby) inside
     `with_ga_plug/2` so all outgoing MP POSTs route through the
     ReqCassette plug.
  2. ReqCassette records each unique POST to `/mp/collect` exactly once
     during recording, then replays from disk on subsequent runs.
  3. `assert_cassette_contains_mp_event/3` reads the captured cassette
     and asserts the right event payload was POSTed.

  The cassette IS the contract — if a future change drops or warps the
  dispatch, the cassette won't contain the expected POST and the
  assertion fails.

  ## Example

      with_cassette "812_signup_magic_link", cassette_opts(), fn plug ->
        with_ga_plug(plug, fn ->
          {:ok, lv, _html} = live(conn, "/users/register")
          lv |> form("#registration_form", user: %{email: "test@example.com"})
             |> render_submit()
        end)
      end

      assert_cassette_contains_mp_event("812_signup_magic_link", "sign_up",
        expected_params: %{"method" => "magic_link"}
      )
  """

  use Boundary, top_level?: true, deps: [CodeMySpec]

  import ExUnit.Assertions

  alias CodeMySpec.Analytics.GoogleAnalytics

  @ga_mp_endpoint "https://www.google-analytics.com/mp/collect"
  @cassette_dir "test/cassettes/analytics"

  @doc """
  Asserts that the cassette at `cassette_name` recorded at least one
  POST to `https://www.google-analytics.com/mp/collect` whose event
  name matches `event_name` (and, optionally, whose params include
  every key/value in `expected_params`).

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
  Installs the cassette plug on the GA MP HTTPAdapter for the
  duration of `fun`, restoring the original plug value (typically
  `nil`) on exit. Use inside `ReqCassette.with_cassette/3`'s callback
  so the cassette captures every MP POST fired by the surface code
  running in `fun`.
  """
  @spec with_ga_plug(any(), (-> any())) :: any()
  def with_ga_plug(plug, fun) do
    original =
      Application.get_env(:code_my_spec, GoogleAnalytics.HTTPAdapter, [])
      |> Keyword.get(:plug)

    Application.put_env(:code_my_spec, GoogleAnalytics.HTTPAdapter, plug: plug)

    try do
      fun.()
    after
      Application.put_env(:code_my_spec, GoogleAnalytics.HTTPAdapter, plug: original)
    end
  end

  # -- Internals --------------------------------------------------------------

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
        Cassette #{path} doesn't exist yet. Record it first by running the
        spex with --include ga_cassette_record.
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
end
