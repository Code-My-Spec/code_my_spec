defmodule CodeMySpec.Workspaces.PreviewTunnelTest do
  @moduledoc """
  Story 968. A preview has to reach an app running somewhere we cannot dial —
  a laptop behind a router, on a network we have never heard of — so the app
  dials out instead, over a named Cloudflare tunnel on our own zone.

  The property worth defending is that the secret is written down. Cloudflare
  returns it at creation and never again; there is no endpoint that re-reads
  it. A second `ensure/1` that created a second tunnel would therefore strand
  the first — a real record in a real account that nothing can speak for and
  nobody will notice — so idempotence here is about not leaking infrastructure,
  not about saving a round trip.

  Every call is stubbed. An unpinned plug plus a token in the environment is a
  live call, and this project has shipped one already.
  """

  use CodeMySpecTest.DataCase, async: true

  # How long to wait for the message the stubbed Cloudflare plug sends back to
  # this process.
  #
  # Naming it rather than leaning on ExUnit's defaults, and naming it once. The
  # two sites below pinned `100` explicitly — not the macro default, a timeout
  # of their own — which stopped `3c8ab289`'s global raise from reaching them.
  # The wait is cross-process either way: the plug reads the request body in
  # Req's connection process and `send/2`s the decoded body from there, so its
  # arrival is scheduling-dependent, not sequenced by anything this test does.
  # Under a loaded gate that is exactly the shape that goes red.
  #
  # A passing assert returns the moment the message lands, so only a genuine
  # failure pays this. `refute_receive` is the one that must not be generous —
  # it waits the whole window by construction — so it gets the short one, which
  # is sound because the thing it asserts *absent* is asserted absent after a
  # synchronous `PreviewTunnel.release/1` has already returned.
  @arrival_timeout 5_000
  @absence_timeout 250

  import CodeMySpec.DevicesFixtures

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpec.Workspaces.PreviewTunnel
  alias Req.Test

  @tunnel_id "d3f1c0de-0000-4000-8000-000000000001"

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user, %{name: "Tunnel #{System.unique_integer()}"})
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope, %{name: "Tunnel project"})
    scope = %{scope | active_project_id: project.id, active_project: project}

    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/tunnel_main")

    %{scope: scope, copy: copy}
  end

  # Two endpoints, one stub. Recording what was asked for is the only way to
  # assert the *shape* of the create call, and the shape is what decides
  # whether cloudflared can use the result at all.
  defp stub_cloudflare(test_pid) do
    Test.stub(PreviewTunnel, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(body)
      send(test_pid, {:cloudflare, conn.request_path, params})

      cloudflare_json(conn, String.contains?(conn.request_path, "cfd_tunnel"))
    end)
  end

  defp cloudflare_json(conn, true),
    do: Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => @tunnel_id}})

  defp cloudflare_json(conn, false),
    do: Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1"}})

  test "provisions a tunnel and points the address at it", %{copy: copy} do
    stub_cloudflare(self())

    assert {:ok, creds} = PreviewTunnel.ensure(copy)

    assert creds.tunnel_id == @tunnel_id
    assert creds.hostname == PreviewAddress.host(copy.id)
    assert creds.account_tag == "test-account"

    assert_receive {:cloudflare, "/client/v4/accounts/test-account/cfd_tunnel", create}
    assert create["name"] == "preview-" <> copy.id

    assert create["config_src"] == "local",
           "cloudflared is configured by the credentials file the checkout holds. " <>
             "Remote config would put the app's own port in a dashboard record we " <>
             "would then have to keep in step with it."

    assert_receive {:cloudflare, "/client/v4/zones/test-zone/dns_records", record}
    assert record["content"] == @tunnel_id <> ".cfargotunnel.com"

    assert record["proxied"] == true,
           "an unproxied CNAME to cfargotunnel.com does not resolve at all — the " <>
             "target only exists inside Cloudflare's edge"
  end

  test "the secret is 32 bytes of real entropy, base64", %{copy: copy} do
    stub_cloudflare(self())

    assert {:ok, creds} = PreviewTunnel.ensure(copy)

    assert {:ok, raw} = Base.decode64(creds.tunnel_secret)

    assert byte_size(raw) == 32,
           "cloudflared refuses a credentials file whose TunnelSecret is not 32 bytes"
  end

  test "records the address and the credential together", %{scope: scope, copy: copy} do
    stub_cloudflare(self())

    assert {:ok, creds} = PreviewTunnel.ensure(copy)

    assert {:ok, saved} = WorkingCopies.fetch(copy.id)

    assert saved.preview_url == PreviewAddress.url(copy.id)
    assert saved.preview_tunnel_id == @tunnel_id
    assert saved.preview_tunnel_secret == creds.tunnel_secret

    assert WorkingCopies.preview_url(scope) == saved.preview_url,
           "the panel reads it through this, so a value the panel cannot see is not recorded"
  end

  test "a second call reuses the tunnel rather than stranding it", %{copy: copy} do
    stub_cloudflare(self())

    assert {:ok, first} = PreviewTunnel.ensure(copy)
    assert_receive {:cloudflare, "/client/v4/accounts/" <> _, _}
    assert_receive {:cloudflare, "/client/v4/zones/" <> _, _}

    {:ok, reloaded} = WorkingCopies.fetch(copy.id)
    assert {:ok, second} = PreviewTunnel.ensure(reloaded)

    assert second.tunnel_id == first.tunnel_id
    assert second.tunnel_secret == first.tunnel_secret

    refute_receive {:cloudflare, "/client/v4/accounts/" <> _, _},
                   100,
                   "a second tunnel was created. The first one is still in the account " <>
                     "and nothing holds its secret any more, so it can never be used " <>
                     "and nothing will report it."
  end

  # The record, though, is re-asserted. Deleting it by hand in the dashboard
  # should heal on the next call rather than leave a blank frame until somebody
  # works out why.
  test "a second call still re-points the address", %{copy: copy} do
    stub_cloudflare(self())

    assert {:ok, _} = PreviewTunnel.ensure(copy)
    {:ok, reloaded} = WorkingCopies.fetch(copy.id)

    assert_receive {:cloudflare, "/client/v4/zones/" <> _, _}

    assert {:ok, _} = PreviewTunnel.ensure(reloaded)
    assert_receive {:cloudflare, "/client/v4/zones/" <> _, _}
  end

  # 81053 is "a record with that name already exists". It is the ordinary case
  # from the second call onward AND the case where an earlier attempt left a
  # record aimed somewhere else, and treating the two alike is what made a
  # preview resolve to a deleted tunnel for an afternoon.
  describe "when the address is already taken" do
    test "a record already pointing at this tunnel is left alone", ctx do
      taken(self(), @tunnel_id <> ".cfargotunnel.com")

      assert {:ok, _creds} = PreviewTunnel.ensure(ctx.copy)

      refute_receive {:patched, _body},
                     100,
                     "a record already aimed at this tunnel was rewritten anyway"
    end

    test "a record pointing anywhere else is repointed", ctx do
      taken(self(), "some-old-tunnel.cfargotunnel.com")

      assert {:ok, _creds} = PreviewTunnel.ensure(ctx.copy)

      assert_receive {:patched, body},
                     100,
                     "the address was left pointing at another tunnel. Cloudflare " <>
                       "answers 530 for that, which reads as the app being down — so " <>
                       "the whole diagnosis lands on an application that is fine."

      assert body["content"] == @tunnel_id <> ".cfargotunnel.com"
    end
  end

  # Cloudflare refusing the create, then the lookup that follows, then the
  # update. Reports the PATCH body so a test can tell "left alone" from
  # "rewritten", which is the whole distinction here.
  defp taken(test_pid, existing_content) do
    Test.stub(PreviewTunnel, &taken_response(&1, test_pid, existing_content))
  end

  defp taken_response(conn, test_pid, existing_content) do
    cfd_tunnel_response(
      String.contains?(conn.request_path, "cfd_tunnel"),
      conn,
      test_pid,
      existing_content
    )
  end

  defp cfd_tunnel_response(true, conn, _test_pid, _existing_content) do
    Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => @tunnel_id}})
  end

  defp cfd_tunnel_response(false, conn, test_pid, existing_content) do
    method_response(conn.method, conn, test_pid, existing_content)
  end

  defp method_response("PATCH", conn, test_pid, _existing_content) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    send(test_pid, {:patched, Jason.decode!(raw)})

    Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1"}})
  end

  defp method_response("GET", conn, _test_pid, existing_content) do
    Test.json(conn, %{
      "success" => true,
      "errors" => [],
      "result" => [%{"id" => "rec-1", "content" => existing_content}]
    })
  end

  defp method_response(_other, conn, _test_pid, _existing_content) do
    Test.json(conn, %{"success" => false, "errors" => [%{"code" => 81_053}]})
  end

  describe "sharing a device's tunnel (criteria 1586/1587)" do
    setup %{copy: main} do
      {:ok, main} =
        WorkingCopies.record_preview_tunnel(main, %{
          preview_url: PreviewAddress.url(main.id),
          preview_tunnel_id: @tunnel_id,
          preview_tunnel_secret: "main-secret"
        })

      %{main: main}
    end

    defp stub_shared_cloudflare(test_pid, ingress, dns_lookup \\ []) do
      Test.stub(PreviewTunnel, &shared_cloudflare_response(&1, test_pid, ingress, dns_lookup))
    end

    defp shared_cloudflare_response(%{request_path: "/" <> _ = path} = conn, test_pid, ingress, dns_lookup) do
      configurations_response(
        String.contains?(path, "/configurations"),
        conn,
        test_pid,
        ingress,
        dns_lookup
      )
    end

    defp configurations_response(true, %{method: "GET"} = conn, _test_pid, ingress, _dns_lookup) do
      Test.json(conn, %{
        "success" => true,
        "errors" => [],
        "result" => %{"config" => %{"ingress" => ingress}}
      })
    end

    defp configurations_response(true, %{method: "PUT"} = conn, test_pid, _ingress, _dns_lookup) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:put_config, Jason.decode!(body)})
      Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
    end

    defp configurations_response(false, conn, test_pid, _ingress, dns_lookup) do
      dns_response(
        String.contains?(conn.request_path, "dns_records"),
        conn,
        test_pid,
        dns_lookup
      )
    end

    defp dns_response(true, %{method: "POST"} = conn, test_pid, _dns_lookup) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:dns_record, Jason.decode!(body)})
      Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1"}})
    end

    defp dns_response(true, %{method: "GET"} = conn, _test_pid, dns_lookup) do
      Test.json(conn, %{"success" => true, "errors" => [], "result" => dns_lookup})
    end

    defp dns_response(true, %{method: "DELETE"} = conn, test_pid, _dns_lookup) do
      send(test_pid, {:dns_deleted, conn.request_path})
      Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
    end

    defp dns_response(false, conn, _test_pid, _dns_lookup) do
      Test.json(conn, %{"success" => false, "errors" => [%{"code" => 9_999}]})
    end

    # Criterion 1586.
    test "a second copy on main's own device shares main's tunnel", %{
      scope: scope,
      main: main
    } do
      stub_shared_cloudflare(self(), [])

      {:ok, sibling} =
        WorkingCopies.issue(scope, nil, label: "worktree", device: main.device_id)

      {:ok, sibling} =
        WorkingCopies.record_app_status(sibling, %{
          status: "serving",
          url: "http://127.0.0.1:41234"
        })

      assert {:ok, creds} = PreviewTunnel.ensure(sibling)

      assert creds.tunnel_id == @tunnel_id
      assert creds.tunnel_secret == "main-secret"
      assert creds.hostname == PreviewAddress.host(sibling.id)

      assert_receive {:put_config, %{"config" => %{"ingress" => ingress}}}
      assert %{"hostname" => host, "service" => "http://127.0.0.1:41234"} =
               Enum.find(ingress, &(&1["hostname"] == PreviewAddress.host(sibling.id)))

      assert host == PreviewAddress.host(sibling.id)

      assert List.last(ingress) == %{"service" => "http_status:404"},
             "cloudflared refuses a config whose last rule names a host"

      assert_receive {:dns_record, record}
      assert record["content"] == @tunnel_id <> ".cfargotunnel.com"

      {:ok, saved} = WorkingCopies.fetch(sibling.id)
      assert saved.preview_tunnel_id == @tunnel_id
      assert saved.preview_tunnel_secret == "main-secret"
      assert saved.preview_url == PreviewAddress.url(sibling.id)
    end

    # Criterion 1587.
    test "a copy on a different device never shares another device's tunnel", %{
      scope: scope
    } do
      stub_shared_cloudflare(self(), [])

      {:ok, elsewhere} =
        WorkingCopies.issue(scope, nil, label: "worktree", device: device_fixture(scope))

      {:ok, elsewhere} =
        WorkingCopies.record_app_status(elsewhere, %{
          status: "serving",
          url: "http://127.0.0.1:51234"
        })

      assert {:error, :no_tunnel_on_this_device} = PreviewTunnel.ensure(elsewhere)

      refute_receive {:put_config, _}, @absence_timeout
      refute_receive {:dns_record, _}, @absence_timeout

      {:ok, saved} = WorkingCopies.fetch(elsewhere.id)
      assert saved.preview_tunnel_id == nil
    end

    test "an unreachable copy is refused, not silently shared with no address", %{
      scope: scope,
      main: main
    } do
      stub_shared_cloudflare(self(), [])

      {:ok, worktree} =
        WorkingCopies.issue(scope, nil, label: "worktree", device: main.device_id)

      assert {:error, :not_the_main_copy} = PreviewTunnel.ensure(worktree)
      refute_receive {:put_config, _}, @absence_timeout
    end

    test "release/1 drops this copy's ingress rule and DNS record, and clears its address", %{
      scope: scope,
      main: main
    } do
      {:ok, sibling} =
        WorkingCopies.issue(scope, nil, label: "worktree", device: main.device_id)

      {:ok, sibling} =
        WorkingCopies.record_app_status(sibling, %{
          status: "serving",
          url: "http://127.0.0.1:41234"
        })

      host = PreviewAddress.host(sibling.id)

      stub_shared_cloudflare(self(), [%{"hostname" => host, "service" => "http://127.0.0.1:41234"}])
      assert {:ok, _} = PreviewTunnel.ensure(sibling)
      assert_receive {:put_config, _}, @arrival_timeout
      {:ok, sibling} = WorkingCopies.fetch(sibling.id)

      stub_shared_cloudflare(
        self(),
        [
          %{"hostname" => host, "service" => "http://127.0.0.1:41234"},
          %{"service" => "http_status:404"}
        ],
        [%{"id" => "rec-shared-1", "content" => @tunnel_id <> ".cfargotunnel.com"}]
      )

      assert :ok = PreviewTunnel.release(sibling)

      assert_receive {:put_config, %{"config" => %{"ingress" => ingress}}}
      refute Enum.any?(ingress, &(&1["hostname"] == host))

      assert_receive {:dns_deleted, path}
      assert path =~ "rec-shared-1"

      {:ok, saved} = WorkingCopies.fetch(sibling.id)
      assert saved.preview_tunnel_id == nil
      assert saved.preview_tunnel_secret == nil
      assert saved.preview_url == nil
    end

    test "release/1 does nothing when the DNS record was already removed by hand", %{
      scope: scope,
      main: main
    } do
      {:ok, sibling} =
        WorkingCopies.issue(scope, nil, label: "worktree", device: main.device_id)

      {:ok, sibling} =
        WorkingCopies.record_app_status(sibling, %{
          status: "serving",
          url: "http://127.0.0.1:41234"
        })

      host = PreviewAddress.host(sibling.id)

      stub_shared_cloudflare(self(), [%{"hostname" => host, "service" => "http://127.0.0.1:41234"}])
      assert {:ok, _} = PreviewTunnel.ensure(sibling)
      assert_receive {:put_config, _}, @arrival_timeout
      {:ok, sibling} = WorkingCopies.fetch(sibling.id)

      stub_shared_cloudflare(self(), [], [])

      assert :ok = PreviewTunnel.release(sibling)
      refute_receive {:dns_deleted, _}, @absence_timeout

      {:ok, saved} = WorkingCopies.fetch(sibling.id)
      assert saved.preview_tunnel_id == nil
    end

    test "release/1 does nothing to main's own tunnel", %{main: main} do
      assert :ok = PreviewTunnel.release(main)
      {:ok, saved} = WorkingCopies.fetch(main.id)
      assert saved.preview_tunnel_id == @tunnel_id
    end
  end

  test "a worktree is refused before anything is provisioned", %{scope: scope, copy: _copy} do
    stub_cloudflare(self())

    {:ok, worktree} =
      WorkingCopies.issue(scope, nil, label: "worktree", device: device_fixture(scope))

    {:ok, worktree} = WorkingCopies.report_root(worktree, "/tmp/tunnel_worktree")

    refute worktree.main

    assert {:error, :not_the_main_copy} = PreviewTunnel.ensure(worktree)

    # The refusal has to come first, not last. Rejecting at the write would
    # create the tunnel and the record and then decline to remember them,
    # leaving a real tunnel in the account whose secret nothing holds — one per
    # worktree anybody ever ran this against, and nothing would ever report it.
    refute_receive {:cloudflare, _path, _params},
                   100,
                   "a worktree reached Cloudflare before being refused"
  end

  describe "stored_credentials/1" do
    test "answers from the stored row alone, reaching Cloudflare for nothing", %{copy: copy} do
      # No stub at all — a live call here would raise (Req.Test refuses an
      # unpinned request), so this is the test that nothing was made.
      {:ok, copy} =
        WorkingCopies.record_preview_tunnel(copy, %{
          preview_url: PreviewAddress.url(copy.id),
          preview_tunnel_id: @tunnel_id,
          preview_tunnel_secret: "s3cret"
        })

      assert {:ok, creds} = PreviewTunnel.stored_credentials(copy)
      assert creds.tunnel_id == @tunnel_id
      assert creds.tunnel_secret == "s3cret"
      assert creds.hostname == PreviewAddress.host(copy.id)
      assert creds.account_tag == "test-account"
    end

    test "answers :error for a copy holding no tunnel" do
      assert PreviewTunnel.stored_credentials(%CodeMySpec.WorkingCopies.WorkingCopy{
               id: Ecto.UUID.generate()
             }) == :error
    end

    # Same shape a sharing sibling's row carries (criterion 1586) — this
    # function has no opinion on whether *running a connector* for what it
    # returns is main's job alone; that decision belongs to its caller.
    test "answers for a sibling sharing another copy's tunnel too", %{scope: scope} do
      {:ok, sibling} =
        WorkingCopies.issue(scope, nil, label: "worktree", device: device_fixture(scope))

      {:ok, sibling} =
        WorkingCopies.record_app_status(sibling, %{
          status: "serving",
          url: "http://127.0.0.1:41234"
        })

      {:ok, sibling} =
        WorkingCopies.record_preview_tunnel(sibling, %{
          preview_url: PreviewAddress.url(sibling.id),
          preview_tunnel_id: @tunnel_id,
          preview_tunnel_secret: "s3cret"
        })

      assert {:ok, creds} = PreviewTunnel.stored_credentials(sibling)
      assert creds.tunnel_id == @tunnel_id
      assert creds.hostname == PreviewAddress.host(sibling.id)
    end
  end

  describe "account_tag/0" do
    test "answers the configured account id" do
      assert PreviewTunnel.account_tag() == "test-account"
    end
  end
end
