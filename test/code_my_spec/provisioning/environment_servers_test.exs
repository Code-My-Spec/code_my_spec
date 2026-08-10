defmodule CodeMySpec.Provisioning.EnvironmentServersTest do
  @moduledoc """
  One box per environment, which is what having environments is for.

  The existing coverage injects the step's whole result, so the loop that
  actually creates the servers was never exercised. A drill then produced two
  `-prod` servers and no `-uat`, and the deploy failed with "the provider has
  no such server" — a defect that unit tests could have caught in
  milliseconds and instead cost a ten-minute cloud cycle to notice.

  This asserts on what was asked of the provider, which is the part that
  matters and the part no recording can be wrong about.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Provisioning.Steps

  setup do
    scope = full_scope_fixture()

    on_exit(fn -> Application.delete_env(:code_my_spec, Hetzner) end)

    {:ok, scope: scope}
  end

  # Answers every Hetzner call plausibly and reports what was asked for. The
  # step will not finish — it goes on to reach boxes over SSH — but every
  # server it wanted has been requested by then, which is what this is about.
  #
  # Dispatched on method and path by head rather than by `cond`: a branch in a
  # test is a test reacting to state it should control, and the framework's own
  # credo check rejects it. This is a router, and a router reads better as
  # clauses anyway.
  defp record_requests(owner) do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      reply(conn, conn.method, conn.request_path, decode(body), owner)
    end

    Application.put_env(:code_my_spec, Hetzner, api_token: "test-token", plug: plug)
  end

  defp decode(""), do: %{}
  defp decode(body), do: Jason.decode!(body)

  defp reply(conn, "POST", "/v1/servers", payload, owner) do
    send(owner, {:creating, payload["name"]})

    json(conn, %{
      "server" => %{"id" => 1, "name" => payload["name"], "location" => %{"name" => "fsn1"}}
    })
  end

  defp reply(conn, "GET", "/v1/servers", _payload, _owner), do: json(conn, %{"servers" => []})
  defp reply(conn, "GET", "/v1/firewalls", _payload, _owner), do: json(conn, %{"firewalls" => []})
  defp reply(conn, "GET", "/v1/ssh_keys", _payload, _owner), do: json(conn, %{"ssh_keys" => []})
  defp reply(conn, "GET", "/v1/networks", _payload, _owner), do: json(conn, %{"networks" => []})

  defp reply(conn, "POST", "/v1/firewalls", payload, _owner) do
    json(conn, %{"firewall" => %{"id" => 2, "name" => payload["name"], "rules" => []}})
  end

  defp reply(conn, "POST", "/v1/ssh_keys", _payload, _owner) do
    json(conn, %{"ssh_key" => %{"id" => 3, "fingerprint" => "aa:bb"}})
  end

  defp reply(conn, _method, _path, payload, _owner) do
    json(conn, %{"network" => %{"id" => 4, "name" => payload["name"]}})
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(body))
  end

  test "asks for one server per environment, named for it", ctx do
    record_requests(self())

    Steps.run(:server, ctx.scope, [])

    names = collect_names([])

    # `prod` and `uat` are the rows a project starts with. Two servers, two
    # names — the drill asked for `-prod` twice and never for `-uat`, so the
    # environment it was meant to deploy simply did not exist.
    assert length(names) == 2,
           "expected one server per environment, got #{inspect(names)}"

    assert Enum.any?(names, &String.ends_with?(&1, "-prod"))
    assert Enum.any?(names, &String.ends_with?(&1, "-uat"))

    assert names == Enum.uniq(names),
           "the same box was requested twice — one environment has no server at all"
  end

  defp collect_names(acc) do
    receive do
      {:creating, name} -> collect_names([name | acc])
    after
      0 -> Enum.sort(acc)
    end
  end
end
