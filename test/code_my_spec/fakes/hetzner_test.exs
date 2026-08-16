defmodule CodeMySpecSpex.Fakes.HetznerTest do
  @moduledoc """
  The fake's own semantics, checked directly.

  A fake nobody tests is a second implementation nobody trusts. These are the
  behaviours criteria will rest on — that state accumulates, that a duplicate
  is refused, that a delete removes — and each one is a thing a cassette
  cannot do, which is the whole reason the fake exists.
  """
  use ExUnit.Case, async: true

  alias CodeMySpecSpex.Fakes.Hetzner

  setup do
    {:ok, agent} = Agent.start_link(&Hetzner.new/0)
    %{agent: agent}
  end

  defp request(agent, method, path), do: send_request(agent, method, path, nil)
  defp request(agent, method, path, body), do: send_request(agent, method, path, body)

  defp send_request(agent, method, path, nil) do
    Req.request!(req(agent, method, path))
  end

  defp send_request(agent, method, path, body) do
    req(agent, method, path) |> Req.merge(json: body) |> Req.request!()
  end

  defp req(agent, method, path) do
    Req.new(
      method: method,
      url: "https://api.hetzner.cloud/v1" <> path,
      plug: &Hetzner.call(&1, agent)
    )
  end

  test "a created server is in the listing afterwards", %{agent: agent} do
    assert %{status: 201} = request(agent, :post, "/servers", %{"name" => "app-uat"})

    assert %{status: 200, body: %{"servers" => [server]}} = request(agent, :get, "/servers")
    assert server["name"] == "app-uat"
  end

  # The whole of 963/7965, at the layer where it is actually a claim about us.
  test "creating the same name twice is refused, not silently duplicated", %{agent: agent} do
    assert %{status: 201} = request(agent, :post, "/servers", %{"name" => "app-uat"})
    assert %{status: 409} = request(agent, :post, "/servers", %{"name" => "app-uat"})

    assert %{body: %{"servers" => servers}} = request(agent, :get, "/servers")
    assert length(servers) == 1
  end

  # Faithful to the provider and to why the code polls: a fresh box is not
  # ready, and becomes ready shortly after. Promoting on read rather than on a
  # timer keeps it deterministic — the poll always finishes on its second look,
  # so a criterion about waiting can assert that it waited.
  test "a server is starting when made and running once polled", %{agent: agent} do
    %{body: %{"server" => created}} = request(agent, :post, "/servers", %{"name" => "app-uat"})
    assert created["status"] == "starting"

    %{body: %{"servers" => [first]}} = request(agent, :get, "/servers")
    assert first["status"] == "starting"

    %{body: %{"servers" => [second]}} = request(agent, :get, "/servers")
    assert second["status"] == "running"
  end

  test "a deleted server is gone from the listing", %{agent: agent} do
    %{body: %{"server" => server}} = request(agent, :post, "/servers", %{"name" => "app-uat"})
    assert %{status: 200} = request(agent, :delete, "/servers/#{server["id"]}")

    assert %{body: %{"servers" => []}} = request(agent, :get, "/servers")
  end

  test "an ssh key is found by its fingerprint, and not by somebody else's", %{agent: agent} do
    %{body: %{"ssh_key" => key}} =
      request(agent, :post, "/ssh_keys", %{"name" => "builder", "public_key" => "ssh-ed25519 AAA"})

    %{body: %{"ssh_keys" => found}} =
      request(agent, :get, "/ssh_keys?fingerprint=#{key["fingerprint"]}")

    assert [%{"name" => "builder"}] = found

    %{body: %{"ssh_keys" => none}} = request(agent, :get, "/ssh_keys?fingerprint=00:11")
    assert none == []
  end

  test "the same public key twice is a conflict, which is the case the code handles", %{
    agent: agent
  } do
    body = %{"name" => "builder", "public_key" => "ssh-ed25519 AAA"}
    assert %{status: 201} = request(agent, :post, "/ssh_keys", body)
    assert %{status: 409} = request(agent, :post, "/ssh_keys", body)
  end

  # A gap in the fake should read as a gap, not as an empty success.
  test "an unmodelled path says so", %{agent: agent} do
    assert %{status: 501, body: %{"error" => %{"code" => "not_modelled"}}} =
             request(agent, :get, "/volumes")
  end
end
