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

      if String.contains?(conn.request_path, "cfd_tunnel") do
        Test.json(conn, %{
          "success" => true,
          "errors" => [],
          "result" => %{"id" => @tunnel_id}
        })
      else
        Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1"}})
      end
    end)
  end

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
    Test.stub(PreviewTunnel, fn conn ->
      cond do
        String.contains?(conn.request_path, "cfd_tunnel") ->
          Test.json(conn, %{
            "success" => true,
            "errors" => [],
            "result" => %{"id" => @tunnel_id}
          })

        conn.method == "PATCH" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:patched, Jason.decode!(raw)})

          Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1"}})

        conn.method == "GET" ->
          Test.json(conn, %{
            "success" => true,
            "errors" => [],
            "result" => [%{"id" => "rec-1", "content" => existing_content}]
          })

        true ->
          Test.json(conn, %{"success" => false, "errors" => [%{"code" => 81_053}]})
      end
    end)
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
end
