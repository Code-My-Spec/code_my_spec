defmodule CodeMySpecSpex.Fakes.StorageDirectTest do
  @moduledoc """
  The fake answered directly, before anything routes through ExAws.

  Written because the first run through `Provisioning.Storage` hung: ExAws
  retries with backoff, so a fake that raises looks exactly like a slow
  network. Checking the fake on its own separates "the fake is wrong" from
  "the wiring is wrong", which is the distinction that run could not make.
  """
  use ExUnit.Case, async: true

  alias CodeMySpecSpex.Fakes

  setup do
    {:ok, agent} = Agent.start_link(&Fakes.Storage.new/0)
    %{agent: agent}
  end

  defp req(agent, method, path) do
    Req.request!(
      method: method,
      url: "https://fsn1.your-objectstorage.com" <> path,
      plug: &Fakes.Storage.call(&1, agent)
    )
  end

  defp put(agent, path, body) do
    Req.request!(
      method: :put,
      url: "https://fsn1.your-objectstorage.com" <> path,
      body: body,
      plug: &Fakes.Storage.call(&1, agent)
    )
  end

  test "listing buckets at the root answers XML", %{agent: agent} do
    assert %{status: 200, body: body} = req(agent, :get, "/")
    assert body =~ "ListAllMyBucketsResult"
  end

  test "a created bucket appears in the listing", %{agent: agent} do
    assert %{status: 200} = put(agent, "/sams-dumps", "")

    assert %{body: body} = req(agent, :get, "/")
    assert body =~ "<Name>sams-dumps</Name>"
  end

  test "an object round-trips", %{agent: agent} do
    put(agent, "/sams-dumps", "")
    assert %{status: 200} = put(agent, "/sams-dumps/dumps/prod/one.sql.gz", "PGDMP")

    assert %{status: 200, body: "PGDMP"} = req(agent, :get, "/sams-dumps/dumps/prod/one.sql.gz")
  end

  test "listing a bucket answers object XML", %{agent: agent} do
    put(agent, "/sams-dumps", "")
    put(agent, "/sams-dumps/dumps/prod/one.sql.gz", "a")

    assert %{status: 200, body: body} = req(agent, :get, "/sams-dumps")
    assert body =~ "<Key>dumps/prod/one.sql.gz</Key>"
  end
end
