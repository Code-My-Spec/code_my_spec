defmodule CodeMySpec.Google.Ads do
  @moduledoc """
  Hand-written `Req` client for the Google Ads API (REST surface), modeled on
  `CodeMySpec.Google.Ga4` / `CodeMySpec.Google.Gsc`.

  Read functions issue [GAQL](https://developers.google.com/google-ads/api/docs/query/overview)
  queries through `customers/{id}/googleAds:search`; write functions issue
  `:mutate` operations against the relevant resource collection. Each public
  function maps 1:1 to a tool and returns `{:ok, data}` / `{:error, reason}`.
  The `CodeMySpec.McpServers.GoogleAds` tool modules are thin wrappers that
  resolve a token and render the result.

  ## Required headers

  Unlike GA4/GSC, the Google Ads API requires a server-side **developer
  token** on every request (`developer-token`), configured via
  `config :code_my_spec, CodeMySpec.Google.Ads, developer_token: ...` (the
  `GOOGLE_ADS_DEVELOPER_TOKEN` env var in `runtime.exs`). The token is never
  returned to the agent. When operating on an account linked under a manager
  (MCC) account, callers pass `:login_customer_id` and the client sets the
  `login-customer-id` header.

  ## Test injection

  Tests set `config :code_my_spec, #{inspect(__MODULE__)}, plug: plug` to
  route `Req` through a `ReqCassette` plug.
  """

  @base "https://googleads.googleapis.com"
  @version "v17"

  @type token :: String.t()
  @type customer_id :: String.t()
  @type opts :: keyword()
  @type result :: {:ok, map() | list()} | {:error, term()}

  # ── Account discovery ─────────────────────────────────────────────────

  @doc "Lists the resource names of every account the token can access."
  @spec list_accessible_accounts(token) :: result
  def list_accessible_accounts(token) do
    with {:ok, dev_token} <- developer_token() do
      request(:get, url("customers:listAccessibleCustomers"), token, dev_token, [])
    end
  end

  @doc "Returns a 30-day account-level overview (spend, clicks, conversions)."
  @spec get_account_overview(token, customer_id, opts) :: result
  def get_account_overview(token, customer_id, opts \\ []) do
    query = """
    SELECT customer.id, customer.descriptive_name, customer.currency_code, \
    metrics.cost_micros, metrics.clicks, metrics.impressions, metrics.conversions \
    FROM customer WHERE segments.date DURING #{date_range(opts)}\
    """

    search(token, customer_id, query, opts)
  end

  # ── Reporting reads ───────────────────────────────────────────────────

  @doc "Campaign-level performance for the date range (default LAST_30_DAYS)."
  @spec get_campaign_performance(token, customer_id, opts) :: result
  def get_campaign_performance(token, customer_id, opts \\ []) do
    query = """
    SELECT campaign.id, campaign.name, campaign.status, campaign.advertising_channel_type, \
    metrics.cost_micros, metrics.clicks, metrics.impressions, metrics.conversions, \
    metrics.average_cpc FROM campaign WHERE segments.date DURING #{date_range(opts)} \
    ORDER BY metrics.cost_micros DESC#{limit_clause(opts)}\
    """

    search(token, customer_id, query, opts)
  end

  @doc "Ad-group-level performance for the date range."
  @spec get_ad_group_performance(token, customer_id, opts) :: result
  def get_ad_group_performance(token, customer_id, opts \\ []) do
    query = """
    SELECT ad_group.id, ad_group.name, ad_group.status, campaign.name, \
    metrics.cost_micros, metrics.clicks, metrics.impressions, metrics.conversions \
    FROM ad_group WHERE segments.date DURING #{date_range(opts)} \
    ORDER BY metrics.cost_micros DESC#{limit_clause(opts)}\
    """

    search(token, customer_id, query, opts)
  end

  @doc "Keyword-level performance for the date range."
  @spec get_keyword_performance(token, customer_id, opts) :: result
  def get_keyword_performance(token, customer_id, opts \\ []) do
    query = """
    SELECT ad_group_criterion.keyword.text, ad_group_criterion.keyword.match_type, \
    ad_group.name, metrics.cost_micros, metrics.clicks, metrics.impressions, \
    metrics.conversions, metrics.average_cpc FROM keyword_view \
    WHERE segments.date DURING #{date_range(opts)} \
    ORDER BY metrics.cost_micros DESC#{limit_clause(opts)}\
    """

    search(token, customer_id, query, opts)
  end

  @doc "Search-terms report: the actual queries that triggered ads."
  @spec get_search_terms_report(token, customer_id, opts) :: result
  def get_search_terms_report(token, customer_id, opts \\ []) do
    query = """
    SELECT search_term_view.search_term, campaign.name, ad_group.name, \
    metrics.cost_micros, metrics.clicks, metrics.impressions, metrics.conversions \
    FROM search_term_view WHERE segments.date DURING #{date_range(opts)} \
    ORDER BY metrics.cost_micros DESC#{limit_clause(opts)}\
    """

    search(token, customer_id, query, opts)
  end

  @doc "Ad-level performance for the date range."
  @spec get_ad_performance(token, customer_id, opts) :: result
  def get_ad_performance(token, customer_id, opts \\ []) do
    query = """
    SELECT ad_group_ad.ad.id, ad_group_ad.ad.type, ad_group_ad.status, \
    ad_group_ad.policy_summary.approval_status, ad_group.name, \
    metrics.cost_micros, metrics.clicks, metrics.impressions, metrics.conversions \
    FROM ad_group_ad WHERE segments.date DURING #{date_range(opts)}#{limit_clause(opts)}\
    """

    search(token, customer_id, query, opts)
  end

  @doc "Active recommendations Google surfaces for the account."
  @spec get_recommendations(token, customer_id, opts) :: result
  def get_recommendations(token, customer_id, opts \\ []) do
    query =
      "SELECT recommendation.type, recommendation.campaign, recommendation.resource_name " <>
        "FROM recommendation#{limit_clause(opts)}"

    search(token, customer_id, query, opts)
  end

  # ── Writes (mutate) ───────────────────────────────────────────────────

  @doc "Sets a campaign budget's daily amount (micros; 1_000_000 = 1 unit)."
  @spec update_campaign_budget(token, customer_id, String.t(), integer(), opts) :: result
  def update_campaign_budget(token, customer_id, budget_id, amount_micros, opts \\ []) do
    cid = normalize_customer_id(customer_id)

    operation = %{
      "updateMask" => "amount_micros",
      "update" => %{
        "resourceName" => "customers/#{cid}/campaignBudgets/#{budget_id}",
        "amountMicros" => amount_micros
      }
    }

    mutate(token, customer_id, "campaignBudgets", [operation], opts)
  end

  @doc "Sets an ad group criterion's max CPC bid (micros)."
  @spec update_bid(token, customer_id, String.t(), integer(), opts) :: result
  def update_bid(token, customer_id, criterion_resource_name, cpc_bid_micros, opts \\ []) do
    operation = %{
      "updateMask" => "cpc_bid_micros",
      "update" => %{
        "resourceName" => criterion_resource_name,
        "cpcBidMicros" => cpc_bid_micros
      }
    }

    mutate(token, customer_id, "adGroupCriteria", [operation], opts)
  end

  @doc "Sets a campaign's status (ENABLED, PAUSED, REMOVED)."
  @spec update_campaign_status(token, customer_id, String.t(), String.t(), opts) :: result
  def update_campaign_status(token, customer_id, campaign_id, status, opts \\ []) do
    cid = normalize_customer_id(customer_id)

    operation = %{
      "updateMask" => "status",
      "update" => %{
        "resourceName" => "customers/#{cid}/campaigns/#{campaign_id}",
        "status" => status
      }
    }

    mutate(token, customer_id, "campaigns", [operation], opts)
  end

  @doc """
  Adds keywords to an ad group. `keywords` is a list of
  `%{"text" => ..., "match_type" => "EXACT" | "PHRASE" | "BROAD"}`.
  """
  @spec add_keywords(token, customer_id, String.t(), [map()], opts) :: result
  def add_keywords(token, customer_id, ad_group_resource_name, keywords, opts \\ []) do
    operations =
      Enum.map(keywords, fn kw ->
        %{
          "create" => %{
            "adGroup" => ad_group_resource_name,
            "status" => "ENABLED",
            "keyword" => %{
              "text" => Map.fetch!(kw, "text"),
              "matchType" => Map.get(kw, "match_type", "BROAD")
            }
          }
        }
      end)

    mutate(token, customer_id, "adGroupCriteria", operations, opts)
  end

  @doc """
  Adds campaign-level negative keywords. `keywords` is a list of
  `%{"text" => ..., "match_type" => ...}`.
  """
  @spec add_negative_keywords(token, customer_id, String.t(), [map()], opts) :: result
  def add_negative_keywords(token, customer_id, campaign_resource_name, keywords, opts \\ []) do
    operations =
      Enum.map(keywords, fn kw ->
        %{
          "create" => %{
            "campaign" => campaign_resource_name,
            "negative" => true,
            "keyword" => %{
              "text" => Map.fetch!(kw, "text"),
              "matchType" => Map.get(kw, "match_type", "BROAD")
            }
          }
        }
      end)

    mutate(token, customer_id, "campaignCriteria", operations, opts)
  end

  @doc """
  Creates a responsive search ad in an ad group. `headlines` and
  `descriptions` are lists of text strings.
  """
  @spec create_ad(token, customer_id, String.t(), [String.t()], [String.t()], opts) :: result
  def create_ad(token, customer_id, ad_group_resource_name, headlines, descriptions, opts \\ []) do
    operation = %{
      "create" => %{
        "adGroup" => ad_group_resource_name,
        "status" => "PAUSED",
        "ad" => %{
          "responsiveSearchAd" => %{
            "headlines" => Enum.map(headlines, &%{"text" => &1}),
            "descriptions" => Enum.map(descriptions, &%{"text" => &1})
          }
        }
      }
    }

    mutate(token, customer_id, "adGroupAds", [operation], opts)
  end

  # ── GAQL search + mutate ──────────────────────────────────────────────

  # Issues a GAQL search, following nextPageToken and accumulating results.
  defp search(token, customer_id, query, opts, acc \\ [], page_token \\ nil) do
    cid = normalize_customer_id(customer_id)

    with {:ok, dev_token} <- developer_token() do
      body = if page_token, do: %{"query" => query, "pageToken" => page_token}, else: %{"query" => query}

      case request(:post, url("customers/#{cid}/googleAds:search"), token, dev_token, opts, json: body) do
        {:ok, resp} ->
          results = acc ++ Map.get(resp, "results", [])

          case Map.get(resp, "nextPageToken") do
            next when next in [nil, ""] -> {:ok, results}
            next -> search(token, customer_id, query, opts, results, next)
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp mutate(token, customer_id, collection, operations, opts) do
    cid = normalize_customer_id(customer_id)
    body = %{"operations" => operations}

    with {:ok, dev_token} <- developer_token() do
      request(:post, url("customers/#{cid}/#{collection}:mutate"), token, dev_token, opts, json: body)
    end
  end

  # ── Core request ──────────────────────────────────────────────────────

  defp request(method, url, token, dev_token, opts, req_opts \\ []) do
    headers =
      [
        {"authorization", "Bearer #{token}"},
        {"developer-token", dev_token},
        {"accept", "application/json"},
        {"user-agent", "CodeMySpec"}
      ] ++ login_customer_header(opts)

    full_opts =
      [method: method, url: url, headers: headers]
      |> Keyword.merge(req_opts)
      |> Keyword.merge(plug_opt())

    case Req.request(full_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body || %{}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:ads_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  @doc """
  Normalizes a customer id to bare digits, accepting `"123-456-7890"`,
  `"1234567890"`, or `"customers/1234567890"`.
  """
  @spec normalize_customer_id(String.t() | integer()) :: String.t()
  def normalize_customer_id(customer_id) when is_integer(customer_id), do: Integer.to_string(customer_id)

  def normalize_customer_id(customer_id) when is_binary(customer_id) do
    customer_id
    |> String.split("/")
    |> List.last()
    |> String.replace(~r/[^0-9]/, "")
  end

  defp url(path), do: "#{@base}/#{@version}/#{path}"

  defp date_range(opts), do: opts[:date_range] || "LAST_30_DAYS"

  defp limit_clause(opts) do
    case opts[:limit] do
      n when is_integer(n) and n > 0 -> " LIMIT #{n}"
      _ -> ""
    end
  end

  defp login_customer_header(opts) do
    case opts[:login_customer_id] do
      nil -> []
      value -> [{"login-customer-id", normalize_customer_id(value)}]
    end
  end

  # The developer token is read from config at call time and never returned
  # to the agent. A missing token is a configuration error, surfaced to the
  # caller rather than crashing.
  defp developer_token do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:developer_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :no_developer_token}
    end
  end

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, []) |> Keyword.get(:plug) do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
