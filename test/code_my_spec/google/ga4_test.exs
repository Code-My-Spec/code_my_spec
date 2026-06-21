defmodule CodeMySpec.Google.Ga4Test do
  @moduledoc """
  Cassette-backed tests for the Google Analytics (GA4) Req client. One test
  per tool operation, replaying cassettes recorded against the live Admin and
  Data APIs (property "Website", 508773792). See
  `CodeMySpec.GoogleCassetteHelpers` for the record/replay mechanics.

  Assertions are structural rather than value-exact, since the recorded data
  is real and changes over time (and realtime/conversions reports may have no
  rows at record time).
  """

  use ExUnit.Case, async: false

  import ReqCassette
  import CodeMySpec.GoogleCassetteHelpers

  alias CodeMySpec.Google.Ga4

  # Real property recorded against: "Website" under the "Code My Spec" account.
  @prop "508773792"

  setup do
    on_exit(fn -> Application.put_env(:code_my_spec, Ga4, []) end)
    :ok
  end

  defp run(name, fun) do
    with_cassette name, cassette_opts(), fn plug ->
      with_plug(Ga4, plug, fun)
    end
  end

  test "property_rn normalizes integers, numeric strings, and resource names" do
    assert {:ok, "properties/123"} = Ga4.property_rn(123)
    assert {:ok, "properties/123"} = Ga4.property_rn("123")
    assert {:ok, "properties/123"} = Ga4.property_rn("properties/123")
    assert {:error, {:invalid_property_id, "abc"}} = Ga4.property_rn("abc")
  end

  test "get_account_summaries returns account summaries with property summaries" do
    run("ga4/get_account_summaries", fn ->
      assert {:ok, summaries} = Ga4.get_account_summaries(token())
      assert is_list(summaries) and summaries != []
      assert Enum.all?(summaries, &Map.has_key?(&1, "account"))

      assert Enum.any?(summaries, fn s ->
               Enum.any?(Map.get(s, "propertySummaries", []), &(&1["property"] == "properties/#{@prop}"))
             end)
    end)
  end

  test "list_google_ads_links returns a list of links" do
    run("ga4/list_google_ads_links", fn ->
      assert {:ok, links} = Ga4.list_google_ads_links(token(), @prop)
      assert is_list(links)
    end)
  end

  test "get_property_details returns the property resource" do
    run("ga4/get_property_details", fn ->
      assert {:ok, data} = Ga4.get_property_details(token(), @prop)
      assert data["name"] == "properties/#{@prop}"
      assert is_binary(data["displayName"])
    end)
  end

  test "list_property_annotations returns a list of annotations" do
    run("ga4/list_property_annotations", fn ->
      assert {:ok, annotations} = Ga4.list_property_annotations(token(), @prop)
      assert is_list(annotations)
    end)
  end

  test "get_custom_dimensions_and_metrics filters to custom-defined fields" do
    run("ga4/get_custom_dimensions_and_metrics", fn ->
      assert {:ok, data} = Ga4.get_custom_dimensions_and_metrics(token(), @prop)
      assert is_list(data.custom_dimensions)
      assert is_list(data.custom_metrics)
      # The filter must only keep custom-defined fields.
      assert Enum.all?(data.custom_dimensions, &(&1["customDefinition"] == true))
      assert Enum.all?(data.custom_metrics, &(&1["customDefinition"] == true))
    end)
  end

  test "run_report posts a report request and returns headers + rows" do
    run("ga4/run_report", fn ->
      opts = [
        date_ranges: [%{"startDate" => "28daysAgo", "endDate" => "today"}],
        dimensions: ["country"],
        metrics: ["activeUsers"],
        limit: 5
      ]

      assert {:ok, data} = Ga4.run_report(token(), @prop, opts)
      assert [%{"name" => "country"}] = data["dimensionHeaders"]
      assert [%{"name" => "activeUsers"} | _] = data["metricHeaders"]
      assert is_list(data["rows"])
    end)
  end

  test "run_report rejects an invalid property id before any request" do
    assert {:error, {:invalid_property_id, "nope"}} =
             Ga4.run_report(token(), "nope", dimensions: ["country"], metrics: ["activeUsers"])
  end

  test "run_realtime_report returns realtime headers" do
    run("ga4/run_realtime_report", fn ->
      opts = [dimensions: ["country"], metrics: ["activeUsers"]]
      assert {:ok, data} = Ga4.run_realtime_report(token(), @prop, opts)
      assert [%{"name" => "country"}] = data["dimensionHeaders"]
    end)
  end

  test "run_conversions_report posts to the alpha endpoint with a conversion spec" do
    run("ga4/run_conversions_report", fn ->
      opts = [
        date_ranges: [%{"startDate" => "28daysAgo", "endDate" => "today"}],
        dimensions: ["sourceMedium"],
        metrics: ["allConversionsByConversionDate"],
        conversion_spec: %{"conversionActions" => []},
        limit: 5
      ]

      assert {:ok, data} = Ga4.run_conversions_report(token(), @prop, opts)
      assert [%{"name" => "sourceMedium"}] = data["dimensionHeaders"]
      assert [%{"name" => "allConversionsByConversionDate"} | _] = data["metricHeaders"]
    end)
  end

  test "run_funnel_report builds event steps and returns a funnel table" do
    run("ga4/run_funnel_report", fn ->
      opts = [
        funnel_steps: [
          %{"name" => "Start", "event" => "session_start"},
          %{"name" => "First visit", "event" => "first_visit"}
        ],
        date_ranges: [%{"startDate" => "28daysAgo", "endDate" => "today"}]
      ]

      assert {:ok, data} = Ga4.run_funnel_report(token(), @prop, opts)
      assert is_list(data["funnelTable"]["dimensionHeaders"])
    end)
  end

  test "run_funnel_report rejects empty funnel steps before any request" do
    assert {:error, :empty_funnel_steps} = Ga4.run_funnel_report(token(), @prop, funnel_steps: [])
  end
end
