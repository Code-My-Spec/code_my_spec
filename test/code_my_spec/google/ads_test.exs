defmodule CodeMySpec.Google.AdsTest do
  @moduledoc """
  Cassette-backed tests for the Google Ads (`CodeMySpec.Google.Ads`) Req
  client. One test per operation, replaying hand-authored cassettes under
  `test/cassettes/google/ads_*.json` that mirror the real Google Ads REST
  shapes. See `CodeMySpec.GoogleCassetteHelpers` for the record/replay
  mechanics.

  Recording (read-only!) against the live API needs both a developer token
  (`GOOGLE_ADS_DEVELOPER_TOKEN`) and an OAuth access token carrying the
  `adwords` scope. The mutate cassettes are authored, never recorded — we do
  not issue real mutations against a live account.
  """

  use ExUnit.Case, async: true

  import ReqCassette
  import CodeMySpec.GoogleCassetteHelpers

  alias CodeMySpec.Google.Ads

  # A test customer id; "123-456-7890" normalizes to "1234567890".
  @customer "123-456-7890"
  @cid "1234567890"

  setup do
    Application.put_env(:code_my_spec, Ads, developer_token: "test-developer-token")
    on_exit(fn -> Application.put_env(:code_my_spec, Ads, []) end)
    :ok
  end

  defp run(name, fun) do
    with_cassette name, cassette_opts(), fn plug ->
      with_plug(Ads, plug, fun)
    end
  end

  test "normalize_customer_id strips dashes, slashes, and resource prefixes" do
    assert Ads.normalize_customer_id("123-456-7890") == "1234567890"
    assert Ads.normalize_customer_id("1234567890") == "1234567890"
    assert Ads.normalize_customer_id("customers/1234567890") == "1234567890"
    assert Ads.normalize_customer_id(1_234_567_890) == "1234567890"
  end

  test "a missing developer token is reported, not crashed" do
    Application.put_env(:code_my_spec, Ads, developer_token: "")
    assert {:error, :no_developer_token} = Ads.list_accessible_accounts("token")
  end

  test "list_accessible_accounts returns the accessible resource names" do
    run("ads/list_accessible_accounts", fn ->
      assert {:ok, data} = Ads.list_accessible_accounts(token())
      assert is_list(data["resourceNames"])
      assert "customers/#{@cid}" in data["resourceNames"]
    end)
  end

  test "get_account_overview returns the customer row with metrics" do
    run("ads/get_account_overview", fn ->
      assert {:ok, results} = Ads.get_account_overview(token(), @customer)
      assert is_list(results)
      assert [%{"customer" => %{"id" => _}, "metrics" => _} | _] = results
    end)
  end

  test "get_campaign_performance returns campaign rows with spend and conversions" do
    run("ads/get_campaign_performance", fn ->
      assert {:ok, results} = Ads.get_campaign_performance(token(), @customer)
      assert is_list(results) and results != []

      assert Enum.all?(results, fn row ->
               Map.has_key?(row, "campaign") and Map.has_key?(row, "metrics")
             end)
    end)
  end

  test "update_campaign_budget issues a campaignBudgets:mutate and returns the result" do
    run("ads/update_campaign_budget", fn ->
      assert {:ok, data} = Ads.update_campaign_budget(token(), @customer, "111", 25_000_000)
      assert [%{"resourceName" => rn} | _] = data["results"]
      assert rn =~ "campaignBudgets"
    end)
  end

  test "add_negative_keywords issues a campaignCriteria:mutate" do
    run("ads/add_negative_keywords", fn ->
      keywords = [%{"text" => "free", "match_type" => "BROAD"}]

      assert {:ok, data} =
               Ads.add_negative_keywords(
                 token(),
                 @customer,
                 "customers/#{@cid}/campaigns/222",
                 keywords
               )

      assert [%{"resourceName" => rn} | _] = data["results"]
      assert rn =~ "campaignCriteria"
    end)
  end

  test "an API quota/policy error surfaces as a tagged ads_error" do
    run("ads/quota_error", fn ->
      assert {:error, {:ads_error, 403, body}} = Ads.get_campaign_performance(token(), @customer)
      assert is_map(body)
    end)
  end
end
