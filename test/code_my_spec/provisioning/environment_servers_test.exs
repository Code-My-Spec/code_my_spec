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
  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Provisioning.Repository
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Provisioning.Storage
  alias CodeMySpec.Servers.Server

  setup do
    scope = full_scope_fixture()
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_api_token", "test-token")

    # The step now refuses before it creates anything when the project has no
    # object-storage key pair, because every box it makes serves the registry
    # and the registry needs them. These tests are about which servers get
    # asked for, so the project is given the pair and the refusal is tested
    # separately.
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_access_key_id", "test-key-id")
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_secret_access_key", "test-secret")

    {:ok, scope: scope}
  end

  test "refuses before making anything when the project has no storage keys", ctx do
    record_requests(self(), :always_available)

    scope = full_scope_fixture()
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_api_token", "test-token")

    assert {:paused, instructions} = Steps.run(:server, scope, [])

    # The storage step's own words, so a project missing one credential is not
    # told two different things by two steps.
    assert instructions == Storage.credentials_instructions()

    # The point of the guard: nothing was asked of the provider. A server was
    # created before this check existed, and it billed from the moment Hetzner
    # accepted it — roughly a minute before the step failed on the missing
    # keys, having waited for SSH on a box it was about to abandon.
    assert collect_names([]) == []

    _ = ctx
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

  # The case "opted out of prod" above stops short of: a project can opt out
  # of every environment it has a row for, not just one of two. `uat` here
  # was never seeded — `EnvironmentRepository.put/3` creates exactly the row
  # it is given, unlike `list/1`, which seeds both on first read — so this is
  # a `prod` row with `devops: :uat` filtering it out, leaving nothing.
  # `ensure_environment_servers/3` used to fan out over that empty list with
  # `Enum.reduce_while([], {:ok, made}, …)`, which returns `{:ok, made}`
  # unchanged and reported the step done having built a firewall and an ssh
  # key and not one box — this is 402f9439, reproduced without touching a
  # real Hetzner project.
  # The re-grain story 879 deferred: an environment linked to an account
  # server (`CodeMySpec.Servers.Server`) already has a real name, and asking
  # for a derived one instead would search for a box that was never going to
  # exist under that name — exactly the shape of bug this step exists to
  # prevent for the un-linked case.
  test "an environment linked to an account server is asked for by that server's own name", ctx do
    record_requests(self(), :always_available)

    # Seeds the initial prod+uat pair first — `put/3` creates exactly the row
    # it's given, unlike `list/1`, so linking straight off a fresh project
    # would leave uat never created at all rather than merely unlinked.
    _ = EnvironmentRepository.list(ctx.scope)

    {:ok, _} = Server.link(ctx.scope, %{name: "fuellytics-prod"})
    linked = Server.get_linked(ctx.scope, "fuellytics-prod")
    {:ok, _} = EnvironmentRepository.put(ctx.scope, "prod", %{server_id: linked.id})

    Steps.run(:server, ctx.scope, [])

    names = collect_names([])

    derived_prod_name = "#{Repository.default_name(ctx.scope.active_project)}-prod"

    assert "fuellytics-prod" in names
    refute derived_prod_name in names,
           "expected the linked environment to be asked for by the server's own name " <>
             "(fuellytics-prod), not the derived #{derived_prod_name} — got #{inspect(names)}"

    assert Enum.any?(names, &String.ends_with?(&1, "-uat")),
           "the unlinked uat environment should still get a derived name"

    assert length(names) == 2, "expected exactly one request per environment, got #{inspect(names)}"
  end

  test "refuses instead of reporting done when every environment is filtered out", ctx do
    {:ok, _} = EnvironmentRepository.put(ctx.scope, "prod", %{})
    {:ok, _} = Configurations.update(ctx.scope, %{devops: :uat})
    record_requests(self(), :always_available)

    assert {:error, reason, _partial} = Steps.run(:server, ctx.scope, [])
    assert reason =~ "no environment is permitted"

    # The point of the guard: no box was asked for. Before this fix the step
    # asked the provider for nothing and still reported success.
    assert collect_names([]) == []
  end

  # Found live against MarketMySpec: prod's registry/database step hit a
  # real, known local-checkout wall on every single rerun of `:server` — and
  # because both environments' boxes ran through one `reduce_while` inside
  # `serve_registries/5`, prod failing first meant uat's registry and
  # database were never even attempted, on any rerun, for hours. Reproduced
  # here with a simpler, deterministic failure (one server's registry
  # command refused) rather than the exact secrets-write crash, because the
  # claim under test is the independence between environments, not why any
  # one of them failed.
  test "one environment's registry/database failing does not block another's", ctx do
    record_full_requests(self(), Repository.default_name(ctx.scope.active_project))

    opts = [
      run: refusing_run("10.0.0.99"),
      credentials: [access_key_id: "unused", secret_access_key: "unused"]
    ]

    assert {:error, reason, resources} = Steps.run(:server, ctx.scope, opts)

    assert reason =~ "uat",
           "expected the failure to name uat, the one whose commands were refused: #{reason}"

    refute reason =~ "prod",
           "prod never failed — naming it here would blame the wrong environment: #{reason}"

    assert Enum.any?(resources, &(&1.kind == "registry" and &1.identifier =~ "environment=prod")),
           "expected prod's registry to be recorded despite uat's failure, got #{inspect(resources)}"

    assert Enum.any?(resources, &(&1.kind == "database" and &1.identifier =~ "environment=prod")),
           "expected prod's database to be recorded despite uat's failure, got #{inspect(resources)}"

    refute Enum.any?(resources, &(&1.kind in ["registry", "database"] and &1.identifier =~ "environment=uat")),
           "uat's registry/database never succeeded — nothing about them should read as done. " <>
             "(uat's own server box is expected here — box creation is a separate, earlier " <>
             "phase this fix does not touch — only its registry and database should be absent)"
  end

  # A `:run` that fails only for commands naming the given private IP —
  # the registry container binds to it (`trust_command/1`), so this reaches
  # every command in that one server's own sequence and none of the other's,
  # without needing to know which docker/ssh command comes first or last.
  defp refusing_run(bad_ip) do
    fn [command] ->
      if String.contains?(command, bad_ip) do
        {"refused", 1}
      else
        {"", 0}
      end
    end
  end

  # Like `record_requests/2`, but with the full network shape
  # `serve_registries/5` actually reads: a private IP per server (so
  # `Hetzner.private_ip/2` resolves) and a public IP (so `serve_one_registry/5`
  # gets past its own address check). Two fixed servers rather than
  # `record_requests/2`'s created-on-demand list, because this test's claim
  # is about what happens *after* both boxes already exist.
  defp record_full_requests(owner, project_name) do
    servers = [
      %{
        "id" => 101,
        "name" => "#{project_name}-prod",
        "location" => %{"name" => "fsn1"},
        "public_net" => %{"ipv4" => %{"ip" => "203.0.113.10"}},
        "private_net" => [%{"network" => 4, "ip" => "10.0.0.10"}]
      },
      %{
        "id" => 102,
        "name" => "#{project_name}-uat",
        "location" => %{"name" => "fsn1"},
        "public_net" => %{"ipv4" => %{"ip" => "203.0.113.99"}},
        "private_net" => [%{"network" => 4, "ip" => "10.0.0.99"}]
      }
    ]

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:ran, conn.method, conn.request_path})
      full_reply(conn, conn.method, conn.request_path, decode(body), servers)
    end

    Req.Test.stub(Hetzner, plug)
  end

  defp full_reply(conn, "GET", "/v1/servers", _payload, servers), do: json(conn, %{"servers" => servers})
  defp full_reply(conn, "GET", "/v1/firewalls", _payload, _servers), do: json(conn, %{"firewalls" => []})
  defp full_reply(conn, "GET", "/v1/ssh_keys", _payload, _servers), do: json(conn, %{"ssh_keys" => []})
  defp full_reply(conn, "GET", "/v1/networks", _payload, _servers), do: json(conn, %{"networks" => []})

  defp full_reply(conn, "POST", "/v1/firewalls", payload, _servers) do
    json(conn, %{"firewall" => %{"id" => 2, "name" => payload["name"], "rules" => []}})
  end

  defp full_reply(conn, "POST", "/v1/ssh_keys", _payload, _servers) do
    json(conn, %{"ssh_key" => %{"id" => 3, "fingerprint" => "aa:bb"}})
  end

  defp full_reply(conn, "POST", "/v1/servers/" <> _rest, _payload, _servers) do
    json(conn, %{"action" => %{"status" => "success"}})
  end

  defp full_reply(conn, _method, _path, payload, _servers) do
    json(conn, %{"network" => %{"id" => 4, "name" => payload["name"]}})
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
