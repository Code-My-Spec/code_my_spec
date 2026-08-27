defmodule CodeMySpec.Provisioning.HetznerTest do
  @moduledoc """
  The HTTP paths are stubbed here. The client was separately exercised against
  the live Hetzner API — a real firewall and server created, idempotence
  confirmed, both destroyed — which is where the `cx22`-is-deprecated and
  arm-capacity findings came from. These tests pin the behaviour that survived
  that, so a regression shows up without needing to spend money again.
  """
  # Sync: writes `:code_my_spec, Hetzner`, shared with
  # `provisioning/environment_servers_test`. The plug half could move to
  # `Req.Test`; the api_token cannot — see the note above `stub/1` for why,
  # and for what would have to change in production first.
  # Async: the api token now reaches the client the way production does —
  # through the scope. `Hetzner.token/1` tries account secrets, then project
  # secrets, and only then the ambient `:code_my_spec, Hetzner` fallback, so a
  # token in a project secret never leaves this test's sandbox. Writing the
  # fallback instead is what pinned this file and
  # `provisioning/environment_servers_test` together, and what made every
  # scope in the suite look configured.
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Provisioning.Hetzner

  doctest Hetzner, only: [fingerprint: 1]
  alias CodeMySpec.ProjectSecrets

  import CodeMySpec.UsersFixtures

  @token_key "hetzner_api_token"

  setup do
    scope = full_scope_fixture()
    {:ok, _} = ProjectSecrets.put_value(scope, @token_key, "test-token")
    %{scope: scope}
  end

  # Sync, and the reason is the token rather than the plug.
  #
  # The plug half could move to `Req.Test`, the way `git_hub_test` and
  # `provisioning/repository_test` now do — a stub registered against the
  # calling process, which two files can hold at once. `api_token` cannot.
  # `Hetzner.token/1` tries account secrets, then project secrets, then this
  # application-environment fallback, so putting a token here does not
  # configure *this* test — it makes every scope in the suite look configured.
  #
  # Tried, and it broke three tests in `ProvisioningLive` and `Provisioning`
  # that mount a page whose `reverify` calls `list_servers/1`. They pass today
  # because no token exists and the call short-circuits to
  # `:hetzner_not_configured`. Giving them stubs instead would change what
  # they assert, since the page acts on what the provider reports.
  #
  # The fix is in production, not here: a credential reached through the scope
  # (account or project secrets, which are sandboxed per test) instead of an
  # ambient fallback. Until then this file and `environment_servers_test` are
  # pinned together by one key.
  defp stub(fun) do
    Req.Test.stub(Hetzner, fun)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "the firewall policy" do
    # Criterion 8004: the database port must never answer from the internet.
    # The cheapest way to keep that true is to have no code path that opens
    # it, so the public rule set is a fixed list rather than a parameter.
    # Asserted on what is reachable from the internet rather than on the whole
    # rule set, because the rule set grew a rule that is not internet-facing at
    # all. Counting rules would have made adding a private one look like
    # opening a port.
    test "opens the deploy and web ports to the internet, and nothing else" do
      assert Hetzner.public_ports() == ["22", "80", "443"]

      public =
        Hetzner.default_firewall_rules()
        |> Enum.filter(&("0.0.0.0/0" in &1.source_ips))
        |> Enum.map(& &1.port)

      assert public == ["22", "80", "443"]
    end

    test "every default rule is inbound" do
      for rule <- Hetzner.default_firewall_rules() do
        assert rule.direction == "in"
      end
    end

    # The registry the deploy pulls from. A cloud firewall filters private
    # traffic too, which is why the builder's push timed out rather than being
    # refused — and a timeout reads as an unreachable host, not as a dropped
    # packet.
    test "the registry port is reachable from the project's own network, and only that" do
      rule = Enum.find(Hetzner.default_firewall_rules(), &(&1.port == "5000"))

      assert rule, "the builder cannot push to a registry the firewall drops"
      assert rule.source_ips == ["10.0.0.0/16"]

      refute "0.0.0.0/0" in rule.source_ips,
             "the registry is not for the internet — it holds every image this project ships"
    end

    test "the database port is absent, not merely unlisted" do
      refute "5432" in Enum.map(Hetzner.default_firewall_rules(), & &1.port)
    end

    # 22 is open because kamal deploys over it as root to the host IP. Leaving
    # it closed made the deploy step impossible, which is how it was found —
    # the server provisioned fine and nothing could ever be put on it.
    #
    # This is safe only because every server is created with an SSH key
    # attached, which is what makes Hetzner disable root password login. If
    # that ever stops being true, 22 open to the world is a password-guessing
    # target, so the two facts are asserted together.
    test "ssh is open, and the server that answers it takes keys only", ctx do
      assert "22" in Enum.map(Hetzner.default_firewall_rules(), & &1.port)

      # Enforced, not documented: without a key Hetzner sets a root password,
      # and a root password reachable on an open 22 is the one combination
      # that must not be possible.
      assert {:error, :ssh_key_required} = Hetzner.create_server(ctx.scope, "keyless")
    end
  end

  describe "architecture defaults" do
    # The user runs x86 in the US for production and arm in Europe because it
    # is cheaper. Both must be reachable without hand-passing a server type.
    test "arm and x86 name different types and regions" do
      arm = Hetzner.defaults_for(:arm)
      x86 = Hetzner.defaults_for(:x86)

      assert arm.server_type != x86.server_type
      assert arm.location != x86.location
    end

    # The whole cx line is retired — the live API answers "server type 104 is
    # deprecated" for cx22 and no cx type appears in /server_types. A default
    # that reintroduces one produces a create that always fails.
    test "no default uses a retired cx server type" do
      for arch <- [:arm, :x86] do
        refute Hetzner.defaults_for(arch).server_type =~ ~r/^cx/
      end
    end
  end

  describe "server_architecture/1" do
    # What we asked for and what exists are different questions, because
    # create_server answers a sold-out region by taking the other architecture.
    # Whatever builds the image has to read this rather than assume.
    test "reports what the provider says the box runs" do
      assert Hetzner.server_architecture(%{"server_type" => %{"architecture" => "arm"}}) ==
               {:ok, :arm}

      assert Hetzner.server_architecture(%{"server_type" => %{"architecture" => "x86"}}) ==
               {:ok, :x86}
    end

    test "reads through the envelope a create comes back in" do
      server = %{"server" => %{"server_type" => %{"architecture" => "x86"}}}
      assert Hetzner.server_architecture(server) == {:ok, :x86}
    end

    # Guessing here is how an unrunnable image gets published: it passes every
    # check we have and dies at container start.
    test "an unrecognised or absent architecture is an error, not a default" do
      assert {:error, {:unknown_architecture, "riscv"}} =
               Hetzner.server_architecture(%{"server_type" => %{"architecture" => "riscv"}})

      assert {:error, :no_architecture_reported} = Hetzner.server_architecture(%{"id" => 1})
    end
  end

  describe "create_server/3" do
    test "sends the arch's defaults", ctx do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert payload["server_type"] == Hetzner.defaults_for(:arm).server_type
        assert payload["location"] == Hetzner.defaults_for(:arm).location

        json(conn, 201, %{"server" => %{"id" => 1, "name" => payload["name"]}})
      end)

      assert {:ok, %{"server" => %{"id" => 1}}} = Hetzner.create_server(ctx.scope, "box", ssh_key_ids: [1])
    end

    test "an explicit option beats the arch default", ctx do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["location"] == "hel1"
        json(conn, 201, %{"server" => %{"id" => 1}})
      end)

      assert {:ok, _} = Hetzner.create_server(ctx.scope, "box", location: "hel1", ssh_key_ids: [1])
    end

    test "surfaces the provider's own error rather than a generic one", ctx do
      stub(fn conn ->
        json(conn, 400, %{"error" => %{"code" => "invalid_input", "message" => "server type 104 is deprecated"}})
      end)

      assert {:error, {:hetzner_error, 400, body}} = Hetzner.create_server(ctx.scope, "box", ssh_key_ids: [1])
      assert body["error"]["message"] =~ "deprecated"
    end

    # A pinned type is the caller saying which box it wants — the builder does
    # exactly this. `create_in/4` re-applies the override to the retry, so
    # falling back would resend the identical request and report the second
    # refusal as a second shortage.
    test "a pinned server type is not retried as the other architecture", ctx do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Agent.update(calls, &[Jason.decode!(body)["server_type"] | &1])
        json(conn, 412, %{"error" => %{"code" => "resource_unavailable"}})
      end)

      assert {:error, {:capacity_unavailable, message}} =
               Hetzner.create_server(ctx.scope, "box", server_type: "cax21", ssh_key_ids: [1])

      assert Agent.get(calls, & &1) == ["cax21"], "the pinned type was retried"

      # The message names what was actually requested. Naming the default sends
      # the reader looking at a server type nobody asked for.
      assert message =~ "cax21"
      refute message =~ Hetzner.defaults_for(:arm).server_type
    end
  end

  describe "ensure_server/3 — idempotence" do
    # Criterion 7965: running a step twice leaves one of everything.
    test "reuses an existing server instead of creating a second", ctx do
      stub(fn
        %{method: "GET"} = conn ->
          json(conn, 200, %{"servers" => [%{"id" => 7, "name" => "box"}]})

        %{method: "POST"} = conn ->
          flunk("ensure_server created a second server when one already existed")
          conn
      end)

      assert {:ok, %{"id" => 7}} = Hetzner.ensure_server(ctx.scope, "box", ssh_key_ids: [1])
    end

    test "creates when absent", ctx do
      stub(fn
        %{method: "GET"} = conn -> json(conn, 200, %{"servers" => []})
        %{method: "POST"} = conn -> json(conn, 201, %{"server" => %{"id" => 9, "name" => "box"}})
      end)

      assert {:ok, %{"id" => 9}} = Hetzner.ensure_server(ctx.scope, "box", ssh_key_ids: [1])
    end

    # `create_server/3`'s payload is the only other place a firewall gets
    # attached, and an adopted server never goes through it — so without this,
    # a box the account already owned stayed under whatever firewall it had
    # (often none) regardless of what `ensure_firewall/2` had just ensured for
    # it.
    test "an adopted server is attached to the firewall it was just ensured", ctx do
      stub(fn
        %{method: "GET"} = conn ->
          json(conn, 200, %{"servers" => [%{"id" => 7, "name" => "box"}]})

        %{method: "POST", request_path: "/v1/firewalls/5/actions/apply_to_resources"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(self(), {:applied_to, Jason.decode!(body)})
          json(conn, 201, %{"actions" => []})

        %{method: "POST"} = conn ->
          flunk("ensure_server created a second server when one already existed")
          conn
      end)

      assert {:ok, %{"id" => 7}} =
               Hetzner.ensure_server(ctx.scope, "box", firewall_ids: [5], ssh_key_ids: [1])

      assert_received {:applied_to, %{"apply_to" => [%{"type" => "server", "server" => %{"id" => 7}}]}}
    end

    test "no firewall_ids given means no attach call at all", ctx do
      stub(fn
        %{method: "GET"} = conn ->
          json(conn, 200, %{"servers" => [%{"id" => 7, "name" => "box"}]})

        %{method: "POST"} = conn ->
          flunk("attached a firewall that was never asked for")
          conn
      end)

      assert {:ok, %{"id" => 7}} = Hetzner.ensure_server(ctx.scope, "box", ssh_key_ids: [1])
    end

    test "a failed attach surfaces as an error rather than a silent adoption", ctx do
      stub(fn
        %{method: "GET"} = conn ->
          json(conn, 200, %{"servers" => [%{"id" => 7, "name" => "box"}]})

        %{method: "POST"} = conn ->
          json(conn, 404, %{"error" => %{"code" => "not_found"}})
      end)

      assert {:error, _} = Hetzner.ensure_server(ctx.scope, "box", firewall_ids: [5])
    end
  end

  describe "find_server/2" do
    # Criterion 7970 checks state against the provider, and 7964 requires a
    # resource deleted behind setup's back to be rebuilt rather than skipped.
    # Both rest on absence being reported as absence.
    test "a server deleted behind setup's back reads as not_found", ctx do
      stub(fn conn -> json(conn, 200, %{"servers" => [%{"id" => 1, "name" => "other"}]}) end)

      assert {:error, :not_found} = Hetzner.find_server(ctx.scope, "box")
    end
  end

  describe "credentials" do
    # A different project, carrying no Hetzner secret — rather than deleting the
    # ambient config, which is node-wide and was the whole reason this file was
    # sync. Nothing configures `:code_my_spec, Hetzner` any more, so the
    # fallback is empty and `token/1` runs out of places to look.
    #
    # This asserted the right thing for the wrong reason once already: with a
    # token on the scope and the config deleted, `list_servers/1` reached the
    # real Hetzner API and came back `{:hetzner_error, 401, ...}` — a live
    # network call from the unit suite, which is what caught it.
    test "an unconfigured token is a named error, not a crash" do
      assert {:error, :hetzner_not_configured} = Hetzner.list_servers(full_scope_fixture())
    end

    test "credential_valid? is false when the provider rejects the token", ctx do
      stub(fn conn -> json(conn, 401, %{"error" => %{"code" => "unauthorized"}}) end)

      refute Hetzner.credential_valid?(ctx.scope)
    end

    test "credential_valid? is true when the account is reachable", ctx do
      stub(fn conn -> json(conn, 200, %{"servers" => []}) end)

      assert Hetzner.credential_valid?(ctx.scope)
    end
  end

  # Adopting an existing firewall used to mean keeping whatever rules it had,
  # so a policy change never reached a project that had run setup before. This
  # module's own principle warns about exactly that — persisted state is a
  # record, not the truth — and it cost three drills: the registry port was
  # opened in code, every run adopted a firewall from before that change, and
  # the builder's push timed out against a rule set nobody had looked at.
  describe "adopting a firewall reconciles its rules" do
    test "stale rules are replaced with the current policy", ctx do
      stub(fn
        %{method: "GET"} = conn ->
          json(conn, 200, %{
            "firewalls" => [
              %{
                "id" => 3,
                "name" => "sam-app",
                "rules" => [
                  %{"direction" => "in", "protocol" => "tcp", "port" => "22",
                    "source_ips" => ["0.0.0.0/0", "::/0"]}
                ]
              }
            ]
          })

        %{method: "POST"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(self(), {:set_rules, Jason.decode!(body)["rules"]})
          json(conn, 201, %{"actions" => []})
      end)

      assert {:ok, %{"id" => 3}} = Hetzner.ensure_firewall(ctx.scope, "sam-app")

      assert_received {:set_rules, rules}

      assert "5000" in Enum.map(rules, & &1["port"]),
             "a firewall adopted from before the registry existed still drops its port"
    end

    # A converged run must make no call, or every setup would rewrite the rules
    # and the API answers with keys we do not send.
    test "rules that already match are left alone", ctx do
      stub(fn
        %{method: "GET"} = conn ->
          rules =
            Enum.map(Hetzner.default_firewall_rules(), fn r ->
              %{
                "direction" => r.direction,
                "protocol" => r.protocol,
                "port" => r.port,
                "source_ips" => r.source_ips,
                "description" => nil
              }
            end)

          json(conn, 200, %{"firewalls" => [%{"id" => 3, "name" => "sam-app", "rules" => rules}]})

        %{method: "POST"} = conn ->
          flunk("a converged firewall was rewritten")
          conn
      end)

      assert {:ok, _} = Hetzner.ensure_firewall(ctx.scope, "sam-app")
    end
  end

  # The registry the deploy pulls from lives on this network rather than on a
  # public address. Both the app's server and the ephemeral builder attach, so
  # one image reference is correct in both places — which loopback cannot do,
  # being true on only one machine.
  describe "private networks" do
    test "a network is created with a subnet, because a server cannot attach without one", ctx do
      stub(fn
        %{method: "GET"} = conn ->
          json(conn, 200, %{"networks" => []})

        %{method: "POST"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          payload = Jason.decode!(body)

          send(self(), {:created, payload})

          json(conn, 201, %{"network" => %{"id" => 7, "name" => payload["name"]}})
      end)

      assert {:ok, %{"id" => 7}} = Hetzner.ensure_network(ctx.scope, "sam-app")

      assert_received {:created, payload}

      # A network with no subnet accepts the attach call and then hands out no
      # address, which surfaces later as a registry bound to nothing.
      assert [%{"ip_range" => _}] = payload["subnets"]
      assert payload["ip_range"] == "10.0.0.0/16"
    end

    # A network's subnet lives in exactly one zone and a server can only reach a
    # subnet in its own. The app servers default to `ash` for x86 while the
    # builder was pinned to `fsn1` and the subnet hardcoded `eu-central`: both
    # boxes held 10.0.0.x addresses with routes, and ping got 100% packet loss.
    test "the subnet is created in the zone its servers are actually in", ctx do
      stub(fn
        %{method: "GET"} = conn ->
          json(conn, 200, %{"networks" => []})

        %{method: "POST"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(self(), {:created, Jason.decode!(body)})
          json(conn, 201, %{"network" => %{"id" => 7}})
      end)

      assert {:ok, _} = Hetzner.ensure_network(ctx.scope, "sam-app", network_zone: "us-east")

      assert_received {:created, payload}
      assert [%{"network_zone" => "us-east"}] = payload["subnets"]
    end

    test "a location maps to the zone its network must live in" do
      assert Hetzner.network_zone("ash") == "us-east"
      assert Hetzner.network_zone("fsn1") == "eu-central"

      refute Hetzner.network_zone("ash") == Hetzner.network_zone("fsn1"),
             "the whole failure was treating one as the other"
    end

    test "an existing network is adopted rather than duplicated", ctx do
      stub(fn
        %{method: "GET"} = conn ->
          json(conn, 200, %{"networks" => [%{"id" => 7, "name" => "sam-app"}]})

        %{method: "POST"} = conn ->
          flunk("ensure_network created a second network when one already existed")
          conn
      end)

      assert {:ok, %{"id" => 7, "__adopted__" => true}} = Hetzner.ensure_network(ctx.scope, "sam-app")
    end

    # Setup runs more than once and Hetzner answers a repeat attach with 409.
    # Reporting that as failure would make the second run of an idempotent step
    # fail, which is the opposite of what re-running is for.
    test "attaching a server that is already attached is success", ctx do
      stub(fn conn ->
        json(conn, 409, %{"error" => %{"code" => "server_already_attached"}})
      end)

      assert {:ok, :already_attached} = Hetzner.attach_to_network(ctx.scope, 1, 7)
    end

    # 422 is what Hetzner actually answers, which the 409 above was written
    # from an assumption about. The idempotence was decorative for as long as
    # that was the only case covered: a drill failed its whole deploy on
    # `server_already_attached`, which is the state the call is trying to
    # reach.
    test "already attached is success at the status the provider really sends", ctx do
      stub(fn conn ->
        json(conn, 422, %{
          "error" => %{"code" => "server_already_attached", "message" => "server already attached"}
        })
      end)

      assert {:ok, :already_attached} = Hetzner.attach_to_network(ctx.scope, 1, 7)
    end

    # 422 is not a synonym for "already attached" — it covers a network that
    # is full, a subnet that does not exist, and more. Swallowing all of them
    # would turn a real failure into a deploy that proceeds without a network.
    test "a different 422 is still a failure", ctx do
      stub(fn conn ->
        json(conn, 422, %{"error" => %{"code" => "no_subnet_available"}})
      end)

      assert {:error, {:hetzner_error, 422, _}} = Hetzner.attach_to_network(ctx.scope, 1, 7)
    end

    test "attaching a server that is not attached yet is success", ctx do
      stub(fn conn -> json(conn, 201, %{"action" => %{"status" => "running"}}) end)

      assert {:ok, :attached} = Hetzner.attach_to_network(ctx.scope, 1, 7)
    end
  end

  # Hetzner assigns the address; the attach call does not report it. Guessing
  # the next free one in the subnet is how two servers end up believing they
  # share an address.
  describe "private_ip/2" do
    test "reads the address the server holds on that network" do
      server = %{"private_net" => [%{"network" => 7, "ip" => "10.0.0.3"}]}

      assert {:ok, "10.0.0.3"} = Hetzner.private_ip(server, 7)
    end

    test "an address on another network is not this one's" do
      server = %{"private_net" => [%{"network" => 9, "ip" => "10.0.0.3"}]}

      assert {:error, :no_private_address} = Hetzner.private_ip(server, 7)
    end

    test "a server on no network has no address to report" do
      assert {:error, :no_private_address} = Hetzner.private_ip(%{"private_net" => []}, 7)
      assert {:error, :no_private_address} = Hetzner.private_ip(%{}, 7)
    end

    test "reads through the wrapper the API returns" do
      wrapped = %{"server" => %{"private_net" => [%{"network" => 7, "ip" => "10.0.0.4"}]}}

      assert {:ok, "10.0.0.4"} = Hetzner.private_ip(wrapped, 7)
    end
  end
end
