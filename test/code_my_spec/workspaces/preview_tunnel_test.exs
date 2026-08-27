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

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpec.Workspaces.PreviewTunnel

  @tunnel_id "d3f1c0de-0000-4000-8000-000000000001"

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user, %{name: "Tunnel #{System.unique_integer()}"})
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope, %{name: "Tunnel project"})
    scope = %{scope | active_project_id: project.id, active_project: project}

    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "main")
    {:ok, copy} = WorkingCopies.report_root(copy, "/tmp/tunnel_main")

    %{scope: scope, copy: copy}
  end

  # Two endpoints, one stub. Recording what was asked for is the only way to
  # assert the *shape* of the create call, and the shape is what decides
  # whether cloudflared can use the result at all.
  defp stub_cloudflare(test_pid) do
    Req.Test.stub(PreviewTunnel, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(body)
      send(test_pid, {:cloudflare, conn.request_path, params})

      cond do
        String.contains?(conn.request_path, "cfd_tunnel") ->
          Req.Test.json(conn, %{"success" => true, "result" => %{"id" => @tunnel_id}})

        true ->
          Req.Test.json(conn, %{"success" => true, "result" => %{"id" => "rec-1"}})
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

  test "an existing record is success, not a failure", %{copy: copy} do
    Req.Test.stub(PreviewTunnel, fn conn ->
      if String.contains?(conn.request_path, "cfd_tunnel") do
        Req.Test.json(conn, %{"success" => true, "result" => %{"id" => @tunnel_id}})
      else
        # 81053 is "a record with that name already exists", which is the
        # ordinary case from the second call onward.
        Req.Test.json(conn, %{"success" => false, "errors" => [%{"code" => 81_053}]})
      end
    end)

    assert {:ok, _creds} = PreviewTunnel.ensure(copy)
  end

  test "a worktree is refused before anything is provisioned", %{scope: scope, copy: _copy} do
    stub_cloudflare(self())

    {:ok, worktree} = WorkingCopies.issue(scope, nil, label: "worktree")
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
