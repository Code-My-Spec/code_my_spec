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

    assert length(names) == 2,
           "expected exactly one request per environment, got #{inspect(names)}"
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
  test "environments already networked on shared servers join that network instead of creating one",
       ctx do
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

  # The shape that survived the first fix's own test but not real Hetzner:
  # fuellytics and fuellytics-prod each already had their *own* network
  # before either was ever linked to a second project — never the same one,
  # because nothing provisioned them together. The first attempt at this fix
  # keyed adoption by zone and required every server in a zone to agree on
  # one existing network before adopting anything; two servers in the same
  # zone on two different pre-existing networks disagreed, so it fell
  # through to create-and-collide — the exact bug, reproduced live on the
  # second attempt to onboard broken_oaths. Per-server adoption has no such
  # requirement.
  test "two independently pre-existing servers each keep their own network, not one shared",
       ctx do
    record_two_independent_networks_requests(self())

    link_environment(ctx.scope, "prod", "fuellytics-prod")
    link_environment(ctx.scope, "uat", "fuellytics")

    opts = [
      run: already_provisioned_run(succeeding_run()),
      credentials: [access_key_id: "unused", secret_access_key: "unused"]
    ]

    assert {:ok, resources} = Steps.run(:server, ctx.scope, opts)

    refute_received {:ran, "POST", "/v1/networks", _payload},
                    "expected both already-existing networks to be adopted, not a new one created"

    network_resources = Enum.filter(resources, &(&1.kind == "network"))

    assert length(network_resources) == 2,
           "expected each server's own pre-existing network recorded separately, got #{inspect(network_resources)}"

    assert Enum.all?(network_resources, &(&1.origin == "adopted")),
           "expected both networks to record as adopted — teardown must never delete infrastructure " <>
             "another project's servers still depend on"
  end

  # Exposed publicly for a caller writing a generated file (`config/
  # deploy.yml`'s `registry: server:`), not only for `run(:server, …)`'s own
  # internal use. Two environments on these same two boxes get two different
  # real addresses — a single project-wide default cannot be right for both.
  test "registry_address/3 resolves each environment's own server, not one shared value", ctx do
    record_two_independent_networks_requests(self())

    link_environment(ctx.scope, "prod", "fuellytics-prod")
    link_environment(ctx.scope, "uat", "fuellytics")

    assert {:ok, "10.0.0.2:5000"} = Steps.registry_address(ctx.scope, "prod")
    assert {:ok, "10.1.0.2:5000"} = Steps.registry_address(ctx.scope, "uat")
  end

  test "registry_address/3 reports not provisioned for an environment with no linked server",
       ctx do
    record_two_independent_networks_requests(self())

    assert {:error, :not_provisioned} = Steps.registry_address(ctx.scope, "prod")
  end

  # Confirmed live against broken_oaths: `fuellytics` (location `nbg1`,
  # zone eu-central) carries TWO network attachments — `market-my-spec`
  # (zone us-east) first in `private_net`, from a different project's own
  # history, then its real eu-central one second. Blindly taking the first
  # entry handed a us-east network to a *new* Hetzner request built for an
  # eu-central resource, and Hetzner refused it ("networks must be in the
  # same network zone") — even though the existing, wrong-zone attachment
  # is tolerated on the server that already holds it. The zone-matching
  # entry, wherever it sits in the list, is the one that has to win.
  test "registry_address/3 picks the network whose zone matches the server's own location, not just the first one",
       ctx do
    record_wrong_zone_first_requests(self())
    link_environment(ctx.scope, "uat", "fuellytics")

    assert {:ok, "10.1.0.2:5000"} = Steps.registry_address(ctx.scope, "uat")
  end

  # fuellytics-prod on its own network (id 55) and fuellytics on a different
  # one (id 66) — both in the same zone (fsn1/eu-central), which is the
  # detail the bug turned on: same zone, different networks.
  defp record_two_independent_networks_requests(owner) do
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
        "private_net" => [%{"network" => 66, "ip" => "10.1.0.2"}]
      }
    ]

    networks = [
      %{
        "id" => 55,
        "name" => "fuellytics-prod",
        "ip_range" => "10.0.0.0/16",
        "subnets" => [%{"network_zone" => "eu-central", "ip_range" => "10.0.0.0/24"}]
      },
      %{
        "id" => 66,
        "name" => "fuellytics",
        "ip_range" => "10.1.0.0/16",
        "subnets" => [%{"network_zone" => "eu-central", "ip_range" => "10.1.0.0/24"}]
      }
    ]

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = if body == "", do: %{}, else: Jason.decode!(body)
      send(owner, {:ran, conn.method, conn.request_path, payload})
      two_networks_reply(conn, conn.method, conn.request_path, payload, servers, networks)
    end

    Req.Test.stub(Hetzner, plug)
  end

  defp two_networks_reply(conn, "GET", "/v1/servers", _payload, servers, _networks),
    do: json(conn, %{"servers" => servers})

  defp two_networks_reply(conn, "GET", "/v1/firewalls", _payload, _servers, _networks),
    do: json(conn, %{"firewalls" => []})

  defp two_networks_reply(conn, "GET", "/v1/ssh_keys", _payload, _servers, _networks),
    do: json(conn, %{"ssh_keys" => []})

  defp two_networks_reply(conn, "GET", "/v1/networks", _payload, _servers, networks),
    do: json(conn, %{"networks" => networks})

  defp two_networks_reply(conn, "POST", "/v1/servers/" <> _rest, _payload, _servers, _networks),
    do: json(conn, %{"action" => %{"status" => "success"}})

  defp two_networks_reply(conn, "POST", "/v1/ssh_keys", _payload, _servers, _networks),
    do: json(conn, %{"ssh_key" => %{"id" => 3, "fingerprint" => "aa:bb"}})

  defp two_networks_reply(conn, "POST", "/v1/firewalls", payload, _servers, _networks),
    do: json(conn, %{"firewall" => %{"id" => 2, "name" => payload["name"], "rules" => []}})

  defp two_networks_reply(conn, _method, _path, payload, _servers, _networks),
    do: json(conn, %{"network" => %{"id" => 1, "name" => payload["name"]}})

  # `fuellytics` in eu-central, carrying a us-east network FIRST in
  # `private_net` and its own, real eu-central network second — the exact
  # shape found live on the account, from a different project's network
  # having been attached to this box before broken_oaths ever existed.
  defp record_wrong_zone_first_requests(owner) do
    servers = [
      %{
        "id" => 302,
        "name" => "fuellytics",
        "location" => %{"name" => "nbg1"},
        "public_net" => %{"ipv4" => %{"ip" => "46.225.105.88"}},
        "private_net" => [
          %{"network" => 55, "ip" => "10.0.0.4"},
          %{"network" => 66, "ip" => "10.1.0.2"}
        ]
      }
    ]

    networks = [
      %{
        "id" => 55,
        "name" => "market-my-spec",
        "ip_range" => "10.0.0.0/16",
        "subnets" => [%{"network_zone" => "us-east", "ip_range" => "10.0.0.0/24"}]
      },
      %{
        "id" => 66,
        "name" => "market-my-spec-eu-central",
        "ip_range" => "10.1.0.0/16",
        "subnets" => [%{"network_zone" => "eu-central", "ip_range" => "10.1.0.0/24"}]
      }
    ]

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = if body == "", do: %{}, else: Jason.decode!(body)
      send(owner, {:ran, conn.method, conn.request_path, payload})
      two_networks_reply(conn, conn.method, conn.request_path, payload, servers, networks)
    end

    Req.Test.stub(Hetzner, plug)
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

    refute Enum.any?(
             resources,
             &(&1.kind in ["registry", "database"] and &1.identifier =~ "environment=uat")
           ),
           "uat's registry/database never succeeded — nothing about them should read as done. " <>
             "(uat's own server box is expected here — box creation is a separate, earlier " <>
             "phase this fix does not touch — only its registry and database should be absent)"
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
        command =~ "docker ps -q -f name=^/cms-registry$" ->
          {"c0ffeec0ffee\n", 0}

        command =~ "docker ps -q -f name=^/cms-postgres$" ->
          {"c0ffeec0ffee\n", 0}

        command =~ "docker inspect --format '{{.Config.Image}}' cms-postgres" ->
          {"pgvector/pgvector:pg18\n", 0}

        true ->
          base_run.(args)
      end
    end
  end

  # Like `record_requests/2`, but with the full network shape
  # `serve_registries/5` actually reads: a private IP per server (so
  # `Hetzner.private_ip/2` resolves) and a public IP (so `serve_one_registry/5`
  # gets past its own address check). Two fixed servers rather than
  # `record_requests/2`'s created-on-demand list, because this test's claim
  # is about what happens *after* both boxes already exist.
  #
  # `private_net` is populated from the very first `GET /v1/servers` — the
  # network is account infrastructure now (`provision_account_server/3`'s
  # job), so by the time a project's own `:server` step ever reaches a
  # server, it is already there to be adopted, not attached by this step.
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

  defp full_reply(conn, "GET", "/v1/servers", _payload, servers),
    do: json(conn, %{"servers" => servers})

  defp full_reply(conn, "GET", "/v1/firewalls", _payload, _servers),
    do: json(conn, %{"firewalls" => []})

  defp full_reply(conn, "GET", "/v1/ssh_keys", _payload, _servers),
    do: json(conn, %{"ssh_keys" => []})

  defp full_reply(conn, "GET", "/v1/networks", _payload, _servers) do
    json(conn, %{
      "networks" => [
        %{
          "id" => 4,
          "name" => "shared",
          "ip_range" => "10.0.0.0/16",
          "subnets" => [%{"network_zone" => "eu-central", "ip_range" => "10.0.0.0/24"}]
        }
      ]
    })
  end

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
      Jason.encode!(%{
        "error" => %{"code" => "resource_unavailable", "message" => "error during placement"}
      })
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
