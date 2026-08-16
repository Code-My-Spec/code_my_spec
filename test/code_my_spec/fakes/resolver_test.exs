defmodule CodeMySpecSpex.Fakes.ResolverTest do
  @moduledoc """
  The resolver answers what the zone holds, and nothing else.

  This is the fake that makes publishing mean *visible*. The dns step writes a
  record and then refuses to call itself done until a public resolver returns
  it — for a stated reason: everything after dns reaches the name rather than
  the address. Under fakes no resolver on the internet has heard of the record,
  so the step correctly reported "no public resolver returns it" and the eight
  steps behind it never ran.

  The pairing is the point: a resolver with a store of its own would let a spex
  publish into one place and resolve from another, and an answer for a record
  nobody published is worth less than no answer at all.
  """
  use ExUnit.Case, async: true

  alias CodeMySpecSpex.Fakes.{Cloudflare, Resolver}

  setup do
    {:ok, agent} = Agent.start_link(fn -> Cloudflare.new("example.com") end)
    %{agent: agent}
  end

  defp publish(agent, attrs) do
    Req.request!(
      Req.new(
        method: :post,
        url: "https://api.cloudflare.com/client/v4/zones/zone-1/dns_records",
        json: attrs,
        plug: &Cloudflare.call(&1, agent)
      )
    )
  end

  defp resolve(agent, name, type) do
    Req.request!(
      Req.new(
        method: :get,
        url: "https://cloudflare-dns.com/dns-query?name=#{name}&type=#{type}",
        plug: &Resolver.call(&1, agent)
      )
    ).body
  end

  test "a published record resolves", %{agent: agent} do
    publish(agent, %{"type" => "A", "name" => "uat.example.com", "content" => "203.0.113.1"})

    assert %{"Answer" => [answer]} = resolve(agent, "uat.example.com", "A")
    assert answer["data"] == "203.0.113.1"
  end

  # NXDOMAIN rather than an empty answer list, because `Dns` reads the status
  # to tell "not there" from "there and empty".
  test "a name nobody published does not resolve", %{agent: agent} do
    assert %{"Status" => 3} = resolve(agent, "nothing.example.com", "A")
    refute Map.has_key?(resolve(agent, "nothing.example.com", "A"), "Answer")
  end

  # Cloudflare stores the apex as `@`, which is how a zone file names it and
  # how the sending records are kept — a resolver that did not understand it
  # would report the apex missing on a zone that has it.
  test "the apex resolves under its own name", %{agent: agent} do
    publish(agent, %{"type" => "A", "name" => "@", "content" => "203.0.113.9"})

    assert %{"Answer" => [answer]} = resolve(agent, "example.com", "A")
    assert answer["data"] == "203.0.113.9"
  end

  # MX priority travels in the data, which is how the real endpoints return it
  # and how `Dns` parses it back out.
  test "an MX answer carries its priority", %{agent: agent} do
    publish(agent, %{
      "type" => "MX",
      "name" => "@",
      "content" => "feedback-smtp.example",
      "priority" => 10
    })

    assert %{"Answer" => [answer]} = resolve(agent, "example.com", "MX")
    assert answer["data"] == "10 feedback-smtp.example"
  end

  test "a record of another type does not answer for this one", %{agent: agent} do
    publish(agent, %{"type" => "TXT", "name" => "send", "content" => "v=spf1"})

    assert %{"Status" => 3} = resolve(agent, "send.example.com", "A")
    assert %{"Answer" => [_]} = resolve(agent, "send.example.com", "TXT")
  end
end
