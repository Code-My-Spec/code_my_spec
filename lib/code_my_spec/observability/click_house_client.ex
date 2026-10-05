defmodule CodeMySpec.Observability.ClickHouseClient do
  @moduledoc """
  The one place a request to a project's ClickHouse telemetry database is
  built, same reasoning as `Research.Http` and `HexPackageFetch`: a
  `Req.Test` plug attached here is attached everywhere this is called from.

  ClickHouse's HTTP interface takes the query as the POST body and named
  parameters as `param_<name>` query-string pairs — `{name:Type}` in the SQL
  text names the placeholder, `param_name=value` supplies it. Binding this
  way, rather than interpolating values into the SQL string, is what keeps
  every caller's `since`/`until`/`trace_id`/etc. from ever becoming a SQL
  injection surface.

  `FORMAT JSONEachRow` returns one JSON object per line, no wrapping array
  and no trailing comma to strip — simpler to parse than ClickHouse's default
  pretty-printed table, and exactly the shape `clickhouse-client` itself
  consumes for scripting.
  """

  require Logger

  @default_timeout to_timeout(second: 15)

  @doc """
  Runs `sql` (with `{name:Type}` placeholders) against the connection
  `conn` describes, binding `params` by name. Returns the decoded rows, or
  `{:error, reason}` — never raises, so a caller can route a transport
  failure and a malformed query through the same `with`.
  """
  @spec query(map(), String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def query(%{url: url, username: username, password: password}, sql, params)
      when is_binary(sql) and is_map(params) do
    req =
      [
        url: url,
        params: Map.new(params, fn {k, v} -> {"param_#{k}", to_string(v)} end),
        headers: [
          {"X-ClickHouse-User", username},
          {"X-ClickHouse-Key", password},
          {"X-ClickHouse-Format", "JSONEachRow"}
        ],
        body: sql,
        receive_timeout: @default_timeout,
        retry: false
      ]
      |> Req.new()
      |> attach_plug()

    case Req.post(req) do
      {:ok, %{status: 200, body: body}} -> {:ok, decode_rows(body)}
      {:ok, %{status: status, body: body}} -> {:error, {:clickhouse_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # One JSON object per non-empty line — see moduledoc. A body already
  # decoded by `Req`'s own JSON step (it sniffs `application/json`-ish
  # content types) arrives as a list already; ClickHouse's JSONEachRow
  # content type does not trip that sniffer, so the normal path is the
  # string branch, with the list branch kept for whichever test seam feeds
  # this a pre-decoded body.
  defp decode_rows(body) when is_list(body), do: body

  defp decode_rows(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp attach_plug(req) do
    # Cassette overrides belong to the calling process; concurrent callers
    # retain the configured transport and their own Req.Test ownership.
    configured = Application.get_env(:code_my_spec, __MODULE__, [])[:plug]

    case Process.get({__MODULE__, :plug}, configured) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end
end
