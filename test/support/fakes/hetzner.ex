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

  @doc """
  Answer a request from the account's state.

  `agent` holds the state; every write goes through it, so two processes
  driving the same test — the test and its LiveView — see one account.
  """
  def call(conn, agent) do
    conn = Conn.fetch_query_params(conn)

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

  defp route("GET", "/servers", _body, _params, state) do
    {{200, %{"servers" => Enum.map(state.servers, &running/1)}}, promote(state)}
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

  defp route("POST", "/servers/" <> rest, _body, _params, state) do
    # `…/actions/attach_to_network`. Nothing downstream reads the attachment,
    # so this succeeds without modelling it — and says so, rather than
    # pretending there is a network to look at.
    _ = rest
    {{201, %{"action" => %{"status" => "success"}}}, state}
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
      "public_net" => %{
        "ipv4" => %{"ip" => "203.0.113.#{state.next_id}"},
        "ipv6" => %{"ip" => "2001:db8::#{state.next_id}"}
      },
      "private_net" => [%{"ip" => "10.0.0.#{state.next_id}"}]
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

  # Hetzner filters `GET /ssh_keys` by `name` or `fingerprint`, and the code
  # uses both — `ensure_access_key/2` looks up by fingerprint precisely so a
  # key renamed by hand is still recognised as ours. Ignoring the filter would
  # hand back somebody else's key, and the lookup would appear to succeed.
  defp matching_keys(state, %{"fingerprint" => print}),
    do: Enum.filter(state.ssh_keys, &(&1["fingerprint"] == print))

  defp matching_keys(state, %{"name" => name}),
    do: Enum.filter(state.ssh_keys, &(&1["name"] == name))

  defp matching_keys(state, _params), do: state.ssh_keys

  # Stable and derived, so the same public key always fingerprints the same way
  # and a second create is recognised as a duplicate.
  defp fingerprint(public_key) do
    :crypto.hash(:md5, public_key)
    |> Base.encode16(case: :lower)
    |> String.to_charlist()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &to_string/1)
  end

  defp error(code, message), do: %{"error" => %{"code" => code, "message" => message}}
end
