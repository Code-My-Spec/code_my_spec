defmodule CodeMySpecSpex.Fakes.Hetzner do
  @moduledoc """
  A Hetzner account that remembers what you did to it.

  Not a recording. A cassette answers a request with what the provider said
  once; this answers with what the provider *would* say given everything this
  test has done — so `POST /servers` then `GET /servers` returns the server,
  and creating the same name twice is one server, which is the whole of
  criterion 7965.

  That difference is why this exists. A recording assumes the response is the
  effect, and for provisioning it never is: a create boots a box, `ssh-keygen`
  writes a key, and a later step reads the world rather than the response. On
  replay the response comes back and the world does not, so the step diverges
  from the run that was recorded. 963/7965 records green and replays red for
  exactly that reason — the recording's first run left a key on disk and the
  replay's does not, so its second run asks for a command nobody recorded.

  ## What it is for, and what it is not for

  Claims about **our logic** — sequencing, idempotency, what we do when a
  resource already exists, what we record afterwards. Those are the criteria
  that cost real servers and minutes today and prove nothing about Hetzner.

  Claims about **reality** — that a box answers over HTTPS, that a certificate
  is real, that mail arrives — cannot be faked and should not be. They belong
  in the drill, live and unrecorded. `test/spex/TESTING_PROVISIONING.md` has
  the split.

  ## Fidelity

  Modelled on the shapes `CodeMySpec.Provisioning.Hetzner` actually reads, and
  on Hetzner's own semantics where they matter to us:

    * a created server is `starting`, and answers `running` on the next read,
      because the code polls for exactly that;
    * `POST /ssh_keys` with a fingerprint that already exists is a 409, which
      is the case `ensure_access_key/2` exists to handle;
    * a deleted resource is gone from the listing, so teardown can be asserted.

  Where it is wrong it will be wrong loudly: an unmodelled path answers 501
  with the method and path in the body, rather than a 200 that quietly means
  nothing.

  ## Use

      setup :fake_hetzner

  The state lives in an Agent for the test's lifetime, and the stub is shared
  so the LiveView process sees it — a `Req.Test` stub is otherwise scoped to
  the process that set it.
  """

  alias Plug.Conn

  @doc "Fresh account state. One per test."
  def new do
    %{servers: [], ssh_keys: [], firewalls: [], networks: [], next_id: 1}
  end

  # A token the account recognises and will not act on.
  #
  # 841/1958's premise, and the distinction it is about: "recognised but
  # refused" is not "bad token", and Sam is sent somewhere different by each.
  # Named rather than inferred from scopes, the same way the GitHub fake names
  # the revoked one — the suite has no model of Hetzner permissions, and
  # inventing one to serve a single criterion would be a second implementation
  # nobody checks.
  @refused "spex-read-only-token"

  @doc """
  Answer a request from the account's state.

  `agent` holds the state; every write goes through it, so two processes
  driving the same test — the test and its LiveView — see one account.
  """
  def call(conn, agent) do
    conn = Conn.fetch_query_params(conn)

    case Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> @refused] -> forbidden(conn)
      _ -> dispatch(conn, agent)
    end
  end

  defp forbidden(conn) do
    body = %{
      "error" => %{
        "code" => "forbidden",
        "message" => "insufficient permissions for this resource"
      }
    }

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(403, Jason.encode!(body))
  end

  defp dispatch(conn, agent) do
    {status, body} =
      Agent.get_and_update(
        agent,
        &route(conn.method, path(conn), body_of(conn), conn.query_params, &1)
      )

    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, Jason.encode!(body))
  end

  defp path(conn), do: conn.request_path |> String.replace_prefix("/v1", "")

  defp body_of(%{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp body_of(%{body_params: params}) when is_map(params), do: params
  defp body_of(_), do: %{}

  # -- servers --

  defp route("GET", "/servers", _body, params, state) do
    {{200, %{"servers" => Enum.map(matching_servers(state, params), &running/1)}}, promote(state)}
  end

  defp route("POST", "/servers", body, _params, state) do
    name = body["name"]

    # Hetzner refuses a duplicate name rather than returning the existing one.
    # `ensure_server/2` is supposed to look first and adopt; answering 409 here
    # is what makes 7965 a real test of that rather than of our optimism.
    case Enum.find(state.servers, &(&1["name"] == name)) do
      nil ->
        {server, state} = create_server(name, body, state)
        {{201, %{"server" => server}}, state}

      _existing ->
        {{409, error("uniqueness_error", "server name #{name} is already used")}, state}
    end
  end

  defp route("DELETE", "/servers/" <> id, _body, _params, state) do
    {{200, %{"action" => %{"status" => "success"}}},
     %{state | servers: Enum.reject(state.servers, &(to_string(&1["id"]) == id))}}
  end

  defp route("POST", "/servers/" <> rest, body, _params, state) do
    # `…/actions/attach_to_network`. Hetzner assigns the private address here
    # rather than at creation — `private_ip/2` reads it back off the server
    # precisely because the attach call does not say which one it handed out.
    # A fake that gave servers an address upfront answered
    # `{:error, :no_private_address}`, because the entry carried no network to
    # match against.
    id = rest |> String.split("/") |> List.first()

    servers =
      Enum.map(state.servers, fn server ->
        attach_if_named(server, id, body["network"])
      end)

    {{201, %{"action" => %{"status" => "success"}}}, %{state | servers: servers}}
  end

  # -- ssh keys --

  defp route("GET", "/ssh_keys", _body, params, state) do
    {{200, %{"ssh_keys" => matching_keys(state, params)}}, state}
  end

  defp route("POST", "/ssh_keys", body, _params, state) do
    print = body["public_key"] |> to_string() |> fingerprint()

    case Enum.find(state.ssh_keys, &(&1["fingerprint"] == print)) do
      nil ->
        key = %{
          "id" => state.next_id,
          "name" => body["name"],
          "fingerprint" => print,
          "public_key" => body["public_key"]
        }

        {{201, %{"ssh_key" => key}},
         %{state | ssh_keys: state.ssh_keys ++ [key], next_id: state.next_id + 1}}

      _existing ->
        {{409, error("uniqueness_error", "key with this fingerprint already exists")}, state}
    end
  end

  defp route("DELETE", "/ssh_keys/" <> id, _body, _params, state) do
    {{204, %{}}, %{state | ssh_keys: Enum.reject(state.ssh_keys, &(to_string(&1["id"]) == id))}}
  end

  # -- firewalls --

  defp route("GET", "/firewalls", _body, _params, state) do
    {{200, %{"firewalls" => state.firewalls}}, state}
  end

  defp route("POST", "/firewalls", body, _params, state) do
    firewall = %{"id" => state.next_id, "name" => body["name"], "rules" => body["rules"] || []}

    {{201, %{"firewall" => firewall}},
     %{state | firewalls: state.firewalls ++ [firewall], next_id: state.next_id + 1}}
  end

  defp route("DELETE", "/firewalls/" <> id, _body, _params, state) do
    {{204, %{}}, %{state | firewalls: Enum.reject(state.firewalls, &(to_string(&1["id"]) == id))}}
  end

  # -- networks --

  defp route("GET", "/networks", _body, _params, state) do
    {{200, %{"networks" => state.networks}}, state}
  end

  defp route("POST", "/networks", body, _params, state) do
    network = %{"id" => state.next_id, "name" => body["name"], "ip_range" => body["ip_range"]}

    {{201, %{"network" => network}},
     %{state | networks: state.networks ++ [network], next_id: state.next_id + 1}}
  end

  defp route("DELETE", "/networks/" <> id, _body, _params, state) do
    {{204, %{}}, %{state | networks: Enum.reject(state.networks, &(to_string(&1["id"]) == id))}}
  end

  # -- catalogue: fixed, because nothing we assert depends on it varying --

  defp route("GET", "/datacenters", _body, _params, state) do
    {{200, %{"datacenters" => [%{"name" => "fsn1-dc14", "location" => %{"name" => "fsn1"}}]}},
     state}
  end

  defp route("GET", "/server_types", _body, _params, state) do
    {{200,
      %{
        "server_types" => [
          %{"id" => 22, "name" => "cx32", "architecture" => "x86", "cores" => 4, "memory" => 8}
        ]
      }}, state}
  end

  # An unmodelled path is a gap in this fake, and should read as one.
  defp route(method, path, _body, _params, state) do
    {{501, error("not_modelled", "#{method} #{path} is not modelled by the Hetzner fake")}, state}
  end

  # -- helpers --

  defp create_server(name, body, state) do
    server = %{
      "id" => state.next_id,
      "name" => name,
      "status" => "starting",
      "server_type" => %{"name" => body["server_type"] || "cx32", "architecture" => "x86"},
      # Where the box is. `join_baseline_network/4` reads it to pick the
      # network zone, and a server without one falls out of that `with` into an
      # `else` that has no clause for it — reported as `no with clause
      # matching` against a list of servers, which names the shape and not the
      # missing field.
      "location" => %{"name" => "fsn1", "network_zone" => "eu-central"},
      "datacenter" => %{
        "name" => "fsn1-dc14",
        "location" => %{"name" => "fsn1", "network_zone" => "eu-central"}
      },
      "public_net" => %{
        "ipv4" => %{"ip" => "203.0.113.#{state.next_id}"},
        "ipv6" => %{"ip" => "2001:db8::#{state.next_id}"}
      },
      # Empty until attached. The address arrives with the attach, which is
      # what `private_ip/2` reads back.
      "private_net" => []
    }

    {server, %{state | servers: state.servers ++ [server], next_id: state.next_id + 1}}
  end

  # A box is `starting` when created and `running` when next asked about, which
  # is what the code polls for. Promoting on read rather than on a timer keeps
  # the test deterministic: the poll finishes on its second look, always.
  defp promote(state) do
    %{state | servers: Enum.map(state.servers, &Map.put(&1, "status", "running"))}
  end

  defp running(server), do: server

  # Hetzner filters `GET /servers` by `name`, and the code uses it to ask
  # whether the server it is about to create is already there. Ignoring the
  # filter hands back every server in the account, so a lookup expecting one
  # match gets two and the caller fails with `no with clause matching` — which
  # names the shape and not the reason.
  defp matching_servers(state, %{"name" => name}),
    do: Enum.filter(state.servers, &(&1["name"] == name))

  defp matching_servers(state, _params), do: state.servers

  # Give the named server an address on the network it just joined.
  defp attach_if_named(%{"id" => server_id} = server, id, network) do
    case to_string(server_id) == id do
      true ->
        entry = %{"network" => network, "ip" => "10.0.0.#{server_id}"}
        Map.update(server, "private_net", [entry], &(&1 ++ [entry]))

      false ->
        server
    end
  end

  # Hetzner filters `GET /ssh_keys` by `name` or `fingerprint`, and the code
  # uses both — `ensure_access_key/2` looks up by fingerprint precisely so a
  # key renamed by hand is still recognised as ours. Ignoring the filter would
  # hand back somebody else's key, and the lookup would appear to succeed.
  defp matching_keys(state, %{"fingerprint" => print}),
    do: Enum.filter(state.ssh_keys, &(&1["fingerprint"] == print))

  defp matching_keys(state, %{"name" => name}),
    do: Enum.filter(state.ssh_keys, &(&1["name"] == name))

  defp matching_keys(state, _params), do: state.ssh_keys

  # Hetzner's own algorithm: md5 of the *decoded* key material — the second
  # field of the public key — rendered as colon-separated hex.
  #
  # Fidelity matters here more than anywhere else in this fake. Hashing the
  # whole string instead gives a stable, plausible, and *different* answer, so
  # `find_ssh_key_by_fingerprint/2` misses, the caller uploads, and this fake
  # rejects the duplicate with a 409 — which reads as the server step not being
  # idempotent. It nearly got reported as a product bug in 963/7965, whose
  # entire subject is idempotency.
  defp fingerprint(public_key) do
    public_key
    |> String.trim()
    |> String.split(~r/\s+/)
    |> Enum.at(1)
    |> decode_material()
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
    |> String.replace(~r/(..)(?!$)/, "\\1:")
  end

  # A key this fake wrote is not real base64 in every case; fall back to the
  # raw field so a malformed one still fingerprints deterministically rather
  # than raising inside a request.
  defp decode_material(nil), do: ""

  defp decode_material(material) do
    case Base.decode64(material) do
      {:ok, decoded} -> decoded
      :error -> material
    end
  end

  defp error(code, message), do: %{"error" => %{"code" => code, "message" => message}}
end
