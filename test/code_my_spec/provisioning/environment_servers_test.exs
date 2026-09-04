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

    # `confirm_new_server` is gone — the hard line removed it, so an
    # environment now reaches the provider only once the account has linked
    # it to a name. Linking to the exact derived name it would have gotten
    # anyway keeps this test's own claim ("one server per environment, named
    # for it") the thing under test, not the linking gate.
    link_derived_environments(ctx.scope, ["prod", "uat"])

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

    link_derived_environments(ctx.scope, ["prod", "uat"])

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

    # Only uat — prod is filtered out by `devops: :uat` before the gate ever
    # sees it, so linking it here would prove nothing the filter doesn't
    # already guarantee.
    link_derived_environments(ctx.scope, ["uat"])

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

    {:ok, _} = Server.link(ctx.scope, %{name: "fuellytics-prod"})
    linked = Server.get_linked(ctx.scope, "fuellytics-prod")
    {:ok, _} = EnvironmentRepository.put(ctx.scope, "prod", %{server_id: linked.id})

    # uat too — the escape hatch that used to let an unlinked environment
    # through with a derived name is gone, so uat needs its own grant to
    # reach the provider at all. Linked to its derived name rather than
    # another arbitrary one, since the claim under test is prod's own name
    # winning over its derived form, not whether uat can be named anything.
    link_derived_environments(ctx.scope, ["uat"])

    Steps.run(:server, ctx.scope, [])

    names = collect_names([])

    derived_prod_name = "#{Repository.default_name(ctx.scope.active_project)}-prod"

    assert "fuellytics-prod" in names
    refute derived_prod_name in names,
           "expected the linked environment to be asked for by the server's own name " <>
             "(fuellytics-prod), not the derived #{derived_prod_name} — got #{inspect(names)}"

    assert Enum.any?(names, &String.ends_with?(&1, "-uat")),
           "expected uat, now linked to its own derived name, to still be asked for"

    assert length(names) == 2, "expected exactly one request per environment, got #{inspect(names)}"
  end

  # Reproduces broken_oaths onboarding live: prod and uat linked to two
  # already-existing, already-networked account servers (fuellytics,
  # fuellytics-prod) that predate this project entirely and already carry a
  # real private address the very first time this step asks about them —
  # unlike every other test here, where the servers are fresh and only
  # `with_private_nets/3`'s post-attach bookkeeping puts one there.
  # `ensure_zone_networks/4` used to derive a network name from *this*
  # project and either find nothing or find the wrong thing, then try to
  # create one — colliding on the range the real network already held
  # (`networks_overlap`, 422). The fix reads the network straight off an
  # already-networked server and adopts it instead.
  test "environments already networked on shared servers join that network instead of creating one", ctx do
    record_shared_network_requests(self())

    link_environment(ctx.scope, "prod", "fuellytics-prod")
    link_environment(ctx.scope, "uat", "fuellytics")

    opts = [
      run: already_provisioned_run(succeeding_run()),
      credentials: [access_key_id: "unused", secret_access_key: "unused"]
    ]

    assert {:ok, resources} = Steps.run(:server, ctx.scope, opts)

    refute_received {:ran, "POST", "/v1/networks", _payload},
                     "expected the already-existing shared network to be adopted, not a new one created"

    assert Enum.any?(resources, &(&1.kind == "network" and &1.origin == "adopted")),
           "expected the network resource to record as adopted, not created — teardown must never " <>
             "delete a network another project's servers still depend on"
  end

  # Two already-existing servers on the account's one real network — the
  # opposite of every other fixture here, which starts servers with no
  # `private_net` at all and only puts one there once `attach_to_network` is
  # actually called (see `with_private_nets/3`'s own comment). fuellytics and
  # fuellytics-prod predate broken_oaths; there is no "before it was
  # attached" for this test to model.
  defp record_shared_network_requests(owner) do
    servers = [
      %{
        "id" => 301,
        "name" => "fuellytics-prod",
        "location" => %{"name" => "fsn1"},
        "public_net" => %{"ipv4" => %{"ip" => "178.156.143.212"}},
        "private_net" => [%{"network" => 55, "ip" => "10.0.0.2"}]
      },
      %{
        "id" => 302,
        "name" => "fuellytics",
        "location" => %{"name" => "fsn1"},
        "public_net" => %{"ipv4" => %{"ip" => "46.225.105.88"}},
        "private_net" => [%{"network" => 55, "ip" => "10.0.0.3"}]
      }
    ]

    network = %{
      "id" => 55,
      "name" => "fuellytics",
      "ip_range" => "10.0.0.0/16",
      "subnets" => [%{"network_zone" => "eu-central", "ip_range" => "10.0.0.0/24"}]
    }

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = if body == "", do: %{}, else: Jason.decode!(body)
      send(owner, {:ran, conn.method, conn.request_path, payload})
      shared_reply(conn, conn.method, conn.request_path, payload, servers, network)
    end

    Req.Test.stub(Hetzner, plug)
  end

  defp shared_reply(conn, "GET", "/v1/servers", _payload, servers, _network),
    do: json(conn, %{"servers" => servers})

  defp shared_reply(conn, "GET", "/v1/firewalls", _payload, _servers, _network),
    do: json(conn, %{"firewalls" => []})

  defp shared_reply(conn, "GET", "/v1/ssh_keys", _payload, _servers, _network),
    do: json(conn, %{"ssh_keys" => []})

  # Named "fuellytics", not anything derived from broken_oaths — proving
  # adoption goes through the server's own `private_net` id, matched
  # against this list by id (`find_network_by_id/2`), never by a name this
  # project's own `network_name_for_zone/3` was never going to produce.
  defp shared_reply(conn, "GET", "/v1/networks", _payload, _servers, network),
    do: json(conn, %{"networks" => [network]})

  defp shared_reply(conn, "POST", "/v1/servers/" <> _rest, _payload, _servers, _network),
    do: json(conn, %{"action" => %{"status" => "success"}})

  defp shared_reply(conn, "POST", "/v1/ssh_keys", _payload, _servers, _network),
    do: json(conn, %{"ssh_key" => %{"id" => 3, "fingerprint" => "aa:bb"}})

  defp shared_reply(conn, "POST", "/v1/firewalls", payload, _servers, _network),
    do: json(conn, %{"firewall" => %{"id" => 2, "name" => payload["name"], "rules" => []}})

  defp shared_reply(conn, _method, _path, payload, _servers, _network),
    do: json(conn, %{"network" => %{"id" => 1, "name" => payload["name"]}})

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
      run: already_provisioned_run(refusing_run("10.0.0.99")),
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

  # The bug this guards: `join_baseline_network/4` used to derive one zone
  # from the *first* server and attach every environment's server to a
  # network in that zone. Hetzner refuses that outright for any server
  # whose own zone differs — a private network's subnet lives in exactly
  # one zone for its life — which is exactly MarketMySpec's real shape:
  # prod in ash (us-east), uat in fsn1 (eu-central), predating this
  # platform's own provisioning and never going to share one network.
  test "environments in different zones each get a network their own box can join", ctx do
    record_zoned_requests(self(), Repository.default_name(ctx.scope.active_project))

    opts = [
      run: already_provisioned_run(succeeding_run()),
      credentials: [access_key_id: "unused", secret_access_key: "unused"]
    ]

    assert {:ok, resources} = Steps.run(:server, ctx.scope, opts)

    network_creates =
      collect_requests([])
      |> Enum.filter(fn {method, path, _payload} -> method == "POST" and path == "/v1/networks" end)
      |> Enum.map(fn {_method, _path, payload} -> payload end)

    zones_asked_for =
      Enum.map(network_creates, &get_in(&1, ["subnets", Access.at(0), "network_zone"]))

    assert Enum.sort(zones_asked_for) == ["eu-central", "us-east"],
           "expected one network per zone this project's boxes actually sit in, got #{inspect(zones_asked_for)}"

    # The actual bug, live: both networks defaulted to the identical
    # hardcoded 10.0.0.0/16 before `create_network/3` took an index, and
    # Hetzner refused the second one outright ("networks_overlap") — same
    # failure family as the zone mismatch, one layer further in.
    ranges_asked_for = Enum.map(network_creates, & &1["ip_range"])

    assert ranges_asked_for == Enum.uniq(ranges_asked_for),
           "expected two non-overlapping ranges, got the same range asked for twice: " <>
             inspect(ranges_asked_for)

    assert "10.0.0.0/16" in ranges_asked_for,
           "expected the primary zone to keep the project's original, already-created range, " <>
             "got #{inspect(ranges_asked_for)}"

    assert Enum.any?(resources, &(&1.kind == "registry" and &1.identifier =~ "environment=prod")),
           "expected prod's registry to be recorded, got #{inspect(resources)}"

    assert Enum.any?(resources, &(&1.kind == "registry" and &1.identifier =~ "environment=uat")),
           "expected uat's registry to be recorded despite sitting in a zone of its own, " <>
             "got #{inspect(resources)}"

    assert length(Enum.filter(resources, &(&1.kind == "network"))) == 2,
           "expected two recorded networks, one per zone, got #{inspect(resources)}"
  end

  # The bug this guards, found live against MarketMySpec on the fix above's
  # own first real run: "primary zone" was guessed from whichever
  # environment `permitted_environment_rows/1` happened to return first —
  # `EnvironmentRepository.list/1` ties nothing to "prod comes first" — and
  # the guess landed on uat's zone. `ensure_zone_networks/4` then handed the
  # project's real, already-existing network (us-east) index 1 and the new
  # one index 0, recreating the exact `10.0.0.0/16` collision this was
  # supposed to prevent — Hetzner adopted the already-existing network
  # unchanged and created the new one at the *wrong* index instead of a
  # genuinely different range.
  #
  # Reading the existing network's own zone back removes the guess
  # entirely for a project that already has one — this asserts the new
  # network gets a non-zero index without needing to control which
  # environment the test fixture happens to answer first.
  test "an existing network's own zone is primary, not whichever environment answers first", ctx do
    record_zoned_requests_with_existing_network(
      self(),
      Repository.default_name(ctx.scope.active_project)
    )

    opts = [
      run: already_provisioned_run(succeeding_run()),
      credentials: [access_key_id: "unused", secret_access_key: "unused"]
    ]

    assert {:ok, _resources} = Steps.run(:server, ctx.scope, opts)

    [{_method, _path, payload}] =
      collect_requests([])
      |> Enum.filter(fn {method, path, _payload} -> method == "POST" and path == "/v1/networks" end)

    assert get_in(payload, ["subnets", Access.at(0), "network_zone"]) == "eu-central",
           "expected the only network *created* to be uat's (the one that does not already exist)"

    refute payload["ip_range"] == "10.0.0.0/16",
           "expected the new network to avoid the existing us-east network's range, got #{inspect(payload)}"
  end

  # Grants the account's link for one environment, the same way the account
  # side of the hard line does it for real (`CodeMySpec.Servers.Server.link/2`
  # then `EnvironmentRepository.put/3`). `confirm_new_server` used to let a
  # project-scoped call reach the provider for a name nobody had approved —
  # removed along with the outage it caused — so every test asserting a
  # server actually gets created now has to grant that first, same as a
  # human would through the servers page or the account agent would through
  # its own tool.
  defp link_environment(scope, environment, name) do
    {:ok, _} = Server.link(scope, %{name: name})
    linked = Server.get_linked(scope, name)
    {:ok, _} = EnvironmentRepository.put(scope, environment, %{server_id: linked.id})
  end

  # Links each environment to the exact derived name `Steps.server_name/3`
  # would have picked for it anyway, so a test asserting "one server per
  # environment, named for it" is still testing that naming — not the
  # linking gate that now stands in front of it.
  defp link_derived_environments(scope, environments) do
    for environment <- environments do
      name = "#{Repository.default_name(scope.active_project)}-#{environment}"
      link_environment(scope, environment, name)
    end
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

  # Succeeds unconditionally — the zone test's claim is about which networks
  # get asked for and which servers land on them, not about any one remote
  # command, so nothing here needs to distinguish one server's commands from
  # the other's the way `refusing_run/1` does.
  defp succeeding_run, do: fn [_command] -> {"", 0} end

  # Answers the registry/database "is it already running" checks as though
  # the account had already brought both shared containers up — the hard
  # line's own split moved that into `Steps.provision_account_server/3`, so
  # this project-scoped step's `:server` run now only ever *finds* them
  # (`Registry.serve/2`/`Database.serve/3` refuse to create either
  # container themselves). Tests in this file are about the project step's
  # own behavior — naming, firewall/network fan-out, one environment's
  # tenant setup failing without blocking another's — not about container
  # bootstrap, which `database_test.exs`/`registry_test.exs` already cover.
  defp already_provisioned_run(base_run) do
    fn [command] = args ->
      cond do
        command =~ "docker ps -q -f name=^/cms-registry$" -> {"c0ffeec0ffee\n", 0}
        command =~ "docker ps -q -f name=^/cms-postgres$" -> {"c0ffeec0ffee\n", 0}
        command =~ "docker inspect --format '{{.Config.Image}}' cms-postgres" -> {"pgvector/pgvector:pg18\n", 0}
        true -> base_run.(args)
      end
    end
  end

  # A server's `private_net` is empty until `attach_to_network` actually
  # happens — true at Hetzner, and now load-bearing here too:
  # `ensure_zone_networks/4` reads a server's *own* `private_net` first, to
  # adopt whatever network it is already on rather than derive a name and
  # collide with one (`networks_overlap`, confirmed live onboarding
  # broken_oaths onto a shared box). A server list that carried `private_net`
  # from the first `GET /v1/servers` — true before this fix needed the
  # distinction — would make every one of these "brand new server" fixtures
  # read as already-networked and skip create entirely. Tracked per test via
  # `attached`, populated only once the attach action for that server id has
  # actually been sent, so the *early* read (before `attach_zone_networks`
  # runs) sees nothing and the *later* one (`serve_one_registry`'s own
  # re-fetch, after) sees exactly what got attached.
  defp attach_to_network_target("POST", "/v1/servers/" <> rest) do
    case String.split(rest, "/") do
      [id_str, "actions", "attach_to_network"] -> {:ok, String.to_integer(id_str)}
      _ -> :error
    end
  end

  defp attach_to_network_target(_method, _path), do: :error

  defp with_private_nets(servers, attached_ids, private_nets) do
    Enum.map(servers, fn server ->
      case MapSet.member?(attached_ids, server["id"]) and Map.get(private_nets, server["id"]) do
        {network_id, ip} -> Map.put(server, "private_net", [%{"network" => network_id, "ip" => ip}])
        _ -> server
      end
    end)
  end

  # Like `record_full_requests/2`, but the two servers sit in different
  # zones (ash/us-east and fsn1/eu-central — the same pairing as
  # MarketMySpec's real prod/uat) and every network creation is answered
  # with an id matching whichever zone the request actually named, rather
  # than one fixed id for the whole project. `GET /v1/networks` still
  # answers `[]`: the claim under test is what gets *created*, and adopting
  # an existing *named* network is `find_baseline_network/2`'s own,
  # already-covered path (adopting one read off a server's own `private_net`
  # is `with_private_nets/3`'s job above, and there is nothing to adopt here
  # until the servers this test starts from have actually been attached).
  defp record_zoned_requests(owner, project_name) do
    base_servers = [
      %{
        "id" => 201,
        "name" => "#{project_name}-prod",
        "location" => %{"name" => "ash"},
        "public_net" => %{"ipv4" => %{"ip" => "203.0.113.10"}}
      },
      %{
        "id" => 202,
        "name" => "#{project_name}-uat",
        "location" => %{"name" => "fsn1"},
        "public_net" => %{"ipv4" => %{"ip" => "203.0.113.99"}}
      }
    ]

    # Zone -> the id its network is fixed to holding, so the id a create
    # request gets back always matches what `with_private_nets/3` reports
    # once that server has been attached.
    network_ids = %{"us-east" => 11, "eu-central" => 12}
    private_nets = %{201 => {11, "10.0.0.10"}, 202 => {12, "10.0.0.99"}}

    {:ok, attached} = Agent.start_link(fn -> MapSet.new() end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = decode(body)
      send(owner, {:ran, conn.method, conn.request_path, payload})

      case attach_to_network_target(conn.method, conn.request_path) do
        {:ok, server_id} -> Agent.update(attached, &MapSet.put(&1, server_id))
        :error -> :ok
      end

      servers = with_private_nets(base_servers, Agent.get(attached, & &1), private_nets)
      zoned_reply(conn, conn.method, conn.request_path, payload, servers, network_ids)
    end

    Req.Test.stub(Hetzner, plug)
  end

  # Like `record_zoned_requests/2`, but `GET /v1/networks` answers with the
  # project's real, already-created network (us-east, `10.0.0.0/16`) instead
  # of `[]` — the exact shape MarketMySpec's account was in when the primary
  # zone was still guessed from environment order rather than read back.
  defp record_zoned_requests_with_existing_network(owner, project_name) do
    base_servers = [
      %{
        "id" => 201,
        "name" => "#{project_name}-prod",
        "location" => %{"name" => "ash"},
        "public_net" => %{"ipv4" => %{"ip" => "203.0.113.10"}}
      },
      %{
        "id" => 202,
        "name" => "#{project_name}-uat",
        "location" => %{"name" => "fsn1"},
        "public_net" => %{"ipv4" => %{"ip" => "203.0.113.99"}}
      }
    ]

    existing_network = %{
      "id" => 11,
      "name" => project_name,
      "ip_range" => "10.0.0.0/16",
      "subnets" => [%{"network_zone" => "us-east", "ip_range" => "10.0.0.0/24"}]
    }

    network_ids = %{"eu-central" => 12}
    private_nets = %{201 => {11, "10.0.0.10"}, 202 => {12, "10.0.0.99"}}

    {:ok, attached} = Agent.start_link(fn -> MapSet.new() end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = decode(body)
      send(owner, {:ran, conn.method, conn.request_path, payload})

      case attach_to_network_target(conn.method, conn.request_path) do
        {:ok, server_id} -> Agent.update(attached, &MapSet.put(&1, server_id))
        :error -> :ok
      end

      servers = with_private_nets(base_servers, Agent.get(attached, & &1), private_nets)

      case {conn.method, conn.request_path} do
        {"GET", "/v1/networks"} -> json(conn, %{"networks" => [existing_network]})
        _ -> zoned_reply(conn, conn.method, conn.request_path, payload, servers, network_ids)
      end
    end

    Req.Test.stub(Hetzner, plug)
  end

  defp zoned_reply(conn, "GET", "/v1/servers", _payload, servers, _ids), do: json(conn, %{"servers" => servers})
  defp zoned_reply(conn, "GET", "/v1/firewalls", _payload, _servers, _ids), do: json(conn, %{"firewalls" => []})
  defp zoned_reply(conn, "GET", "/v1/ssh_keys", _payload, _servers, _ids), do: json(conn, %{"ssh_keys" => []})
  defp zoned_reply(conn, "GET", "/v1/networks", _payload, _servers, _ids), do: json(conn, %{"networks" => []})

  defp zoned_reply(conn, "POST", "/v1/firewalls", payload, _servers, _ids) do
    json(conn, %{"firewall" => %{"id" => 2, "name" => payload["name"], "rules" => []}})
  end

  defp zoned_reply(conn, "POST", "/v1/ssh_keys", _payload, _servers, _ids) do
    json(conn, %{"ssh_key" => %{"id" => 3, "fingerprint" => "aa:bb"}})
  end

  defp zoned_reply(conn, "POST", "/v1/servers/" <> _rest, _payload, _servers, _ids) do
    json(conn, %{"action" => %{"status" => "success"}})
  end

  defp zoned_reply(conn, "POST", "/v1/networks", payload, _servers, ids) do
    zone = get_in(payload, ["subnets", Access.at(0), "network_zone"])
    json(conn, %{"network" => %{"id" => Map.fetch!(ids, zone), "name" => payload["name"]}})
  end

  # Everything else this run touches but does not care about the shape of —
  # firewall/ssh-key attach actions among them, fire-and-forget the same way
  # `full_reply/5`'s own catch-all treats them.
  defp zoned_reply(conn, _method, _path, payload, _servers, _ids) do
    json(conn, %{"network" => %{"id" => 4, "name" => payload["name"]}})
  end

  defp collect_requests(acc) do
    receive do
      {:ran, method, path, payload} -> collect_requests([{method, path, payload} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Like `record_requests/2`, but with the full network shape
  # `serve_registries/5` actually reads: a private IP per server (so
  # `Hetzner.private_ip/2` resolves) and a public IP (so `serve_one_registry/5`
  # gets past its own address check). Two fixed servers rather than
  # `record_requests/2`'s created-on-demand list, because this test's claim
  # is about what happens *after* both boxes already exist.
  defp record_full_requests(owner, project_name) do
    base_servers = [
      %{
        "id" => 101,
        "name" => "#{project_name}-prod",
        "location" => %{"name" => "fsn1"},
        "public_net" => %{"ipv4" => %{"ip" => "203.0.113.10"}}
      },
      %{
        "id" => 102,
        "name" => "#{project_name}-uat",
        "location" => %{"name" => "fsn1"},
        "public_net" => %{"ipv4" => %{"ip" => "203.0.113.99"}}
      }
    ]

    private_nets = %{101 => {4, "10.0.0.10"}, 102 => {4, "10.0.0.99"}}

    {:ok, attached} = Agent.start_link(fn -> MapSet.new() end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:ran, conn.method, conn.request_path})

      case attach_to_network_target(conn.method, conn.request_path) do
        {:ok, server_id} -> Agent.update(attached, &MapSet.put(&1, server_id))
        :error -> :ok
      end

      servers = with_private_nets(base_servers, Agent.get(attached, & &1), private_nets)
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
