defmodule CodeMySpec.Provisioning.EnvironmentServersTest do
  @moduledoc """
  One box per environment, which is what having environments is for.

  The existing coverage injects the step's whole result, so the loop that
  actually creates the servers was never exercised. A drill then produced a
  `-prod` server and no `-uat`, and the deploy failed with "the provider has
  no such server" — a defect that unit tests could have caught in
  milliseconds and instead cost several ten-minute cloud cycles to notice.

  This asserts on what was asked of the provider, which is the part that
  matters and the part no recording can be wrong about.
  """
  # Async: the token is a project secret on this test's own scope, and the plug
  # is a `Req.Test` stub registered against this process. Neither is visible to
  # anything else, which is what the shared `:code_my_spec, Hetzner` key was.
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Provisioning.Steps

  setup do
    scope = full_scope_fixture()
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_api_token", "test-token")
    {:ok, scope: scope}
  end

  test "asks for one server per environment, named for it", ctx do
    record_requests(self(), :always_available)

    Steps.run(:server, ctx.scope, [])

    names = collect_names([])

    # `prod` and `uat` are the rows a project starts with. Two servers, two
    # names — the drill asked only for `-prod`, so the environment it was
    # meant to deploy simply did not exist.
    assert length(names) == 2, "expected one server per environment, got #{inspect(names)}"

    assert Enum.any?(names, &String.ends_with?(&1, "-prod"))
    assert Enum.any?(names, &String.ends_with?(&1, "-uat"))

    assert names == Enum.uniq(names),
           "the same box was requested twice — one environment has no server at all"
  end

  test "still asks for every environment when the first choice is sold out", ctx do
    # What the real API does on every single create: 412 `error during
    # placement` for the arm type, then 201 for the x86 fallback. The
    # always-available stub above passes without exercising that path, and the
    # path is where the drill lost UAT — so the sold-out answer is the test.
    record_requests(self(), :first_attempt_sold_out)

    Steps.run(:server, ctx.scope, [])

    names = collect_names([]) |> Enum.uniq()

    assert Enum.any?(names, &String.ends_with?(&1, "-uat")),
           "asked for #{inspect(names)} — the capacity fallback dropped an environment"

    assert length(names) == 2, "expected both environments, got #{inspect(names)}"
  end

  # The other direction, and the one that costs money when it is wrong.
  #
  # `ProjectConfiguration` says `:uat` means "stand up staging only; the user
  # promotes to prod themselves". Nothing consulted it: `seed/1` creates prod
  # and uat for every project and every step fanned out over both, so a project
  # set to `:uat` finished setup holding a production server, a DNS record and
  # a database it had explicitly opted out of (27749cc8).
  #
  # It hid behind a green, which is why this is a test rather than a drill
  # observation — the prod steps *succeeded*, so `devops_status` reported
  # complete and 841/1962, the criterion whose whole subject is this, passed
  # for the wrong reason.
  #
  # Asserted on what was asked of the provider. A box that is never requested
  # is the only version of this that is actually true; checking rows afterwards
  # would pass on a run that created one and forgot to record it.
  test "asks for no prod server when the project opted out of prod", ctx do
    {:ok, _} = Configurations.update(ctx.scope, %{devops: :uat})
    record_requests(self(), :always_available)

    Steps.run(:server, ctx.scope, [])

    names = collect_names([])

    assert names == Enum.filter(names, &String.ends_with?(&1, "-uat")),
           "asked the provider for #{inspect(names)} on a project set to devops: :uat"

    assert length(names) == 1, "expected staging only, got #{inspect(names)}"
  end

  # Answers every Hetzner call plausibly and reports what was asked for. The
  # step will not finish — it goes on to reach boxes over SSH — but every
  # server it wanted has been requested by then, which is what this is about.
  #
  # Dispatched on method and path by head rather than by `cond`: a branch in a
  # test is a test reacting to state it should control, and the framework's own
  # credo check rejects it. This is a router, and a router reads better as
  # clauses anyway.
  defp record_requests(owner, capacity) do
    {:ok, state} = Agent.start_link(fn -> %{created: [], refused: MapSet.new()} end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      reply(conn, conn.method, conn.request_path, decode(body), {owner, state, capacity})
    end

    Req.Test.stub(Hetzner, plug)
  end

  defp decode(""), do: %{}
  defp decode(body), do: Jason.decode!(body)

  defp reply(conn, "POST", "/v1/servers", payload, {owner, state, capacity}) do
    name = payload["name"]
    send(owner, {:creating, name})

    refused? = Agent.get(state, &MapSet.member?(&1.refused, name))

    create(conn, name, state, sold_out?(capacity, refused?))
  end

  # The list the provider would return, which grows as boxes are made — a
  # stub that always answers `[]` would let a broken loop create the same
  # server twice and still look right.
  defp reply(conn, "GET", "/v1/servers", _payload, {_owner, state, _capacity}) do
    json(conn, %{"servers" => Agent.get(state, & &1.created)})
  end

  defp reply(conn, "GET", "/v1/firewalls", _payload, _ctx), do: json(conn, %{"firewalls" => []})
  defp reply(conn, "GET", "/v1/ssh_keys", _payload, _ctx), do: json(conn, %{"ssh_keys" => []})
  defp reply(conn, "GET", "/v1/networks", _payload, _ctx), do: json(conn, %{"networks" => []})

  defp reply(conn, "POST", "/v1/firewalls", payload, _ctx) do
    json(conn, %{"firewall" => %{"id" => 2, "name" => payload["name"], "rules" => []}})
  end

  defp reply(conn, "POST", "/v1/ssh_keys", _payload, _ctx) do
    json(conn, %{"ssh_key" => %{"id" => 3, "fingerprint" => "aa:bb"}})
  end

  defp reply(conn, _method, _path, payload, _ctx) do
    json(conn, %{"network" => %{"id" => 4, "name" => payload["name"]}})
  end

  # Sold out only on a name's first attempt, exactly like the real API's
  # arm-then-x86 sequence.
  defp sold_out?(:first_attempt_sold_out, false), do: true
  defp sold_out?(_capacity, _refused?), do: false

  defp create(conn, name, state, true) do
    Agent.update(state, &%{&1 | refused: MapSet.put(&1.refused, name)})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      412,
      Jason.encode!(%{"error" => %{"code" => "resource_unavailable", "message" => "error during placement"}})
    )
  end

  defp create(conn, name, state, false) do
    server = %{"id" => :erlang.phash2(name), "name" => name, "location" => %{"name" => "fsn1"}}
    Agent.update(state, &%{&1 | created: [server | &1.created]})

    json(conn, %{"server" => server})
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(body))
  end

  defp collect_names(acc) do
    receive do
      {:creating, name} -> collect_names([name | acc])
    after
      0 -> Enum.sort(acc)
    end
  end
end
