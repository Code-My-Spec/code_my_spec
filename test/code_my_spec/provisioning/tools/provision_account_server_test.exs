defmodule CodeMySpec.Provisioning.Tools.ProvisionAccountServerTest do
  @moduledoc """
  The tool's own wiring: it links before it provisions, and it reports the
  provider's answer honestly. The full success path through a real box's
  registry and database is `Steps.provision_account_server/3`'s own test
  (`provision_account_server_test.exs`) and the spex battery
  (`criterion_1961` et al, via `Fixtures.bootstrap_account_server/3`) — both
  route SSH through a fake shell this tool's own `execute/2` has no seam to
  inject, since a real caller never gets to pass it one either.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Servers

  setup do
    scope = full_scope_fixture()
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_api_token", "test-token")

    # Pre-seeded so `Servers.access_key/1` never falls back to a real
    # `ssh-keygen` — see the sibling `provision_account_server_test.exs` for
    # why that matters under this suite's own parallel load.
    {:ok, _} =
      AccountSecrets.put_value(
        scope,
        "server_ssh_public_key",
        "ssh-ed25519 AAAAfake test-fixture"
      )

    {:ok, _} =
      AccountSecrets.put_value(
        scope,
        "server_ssh_private_key",
        "-----BEGIN FAKE KEY-----\nfixture\n-----END FAKE KEY-----\n"
      )

    {:ok, scope: scope}
  end

  describe "execute/2" do
    test "links the name even though the provider refuses everything after", %{scope: scope} do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:ran, conn.method, conn.request_path})
        refuse(conn)
      end

      Req.Test.stub(Hetzner, plug)

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "provision_account_server",
          %{name: "acme-box"},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      # The provider was reached at all — proof the link did not block on it.
      assert_received {:ran, _method, _path}

      assert Servers.get_linked(scope, "acme-box"),
             "expected the name linked even though the provider refused"
    end

    test "surfaces the provider's refusal rather than swallowing it", %{scope: scope} do
      plug = fn conn -> refuse(conn) end
      Req.Test.stub(Hetzner, plug)

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "provision_account_server",
          %{name: "acme-box"},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
      assert response_text(response) =~ "Could not bring up the server"
    end

    test "linking the same name twice is not an error", %{scope: scope} do
      {:ok, _} = CodeMySpec.Devices.link_provider_machine(scope, %{name: "acme-box"})

      plug = fn conn -> refuse(conn) end
      Req.Test.stub(Hetzner, plug)

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "provision_account_server",
          %{name: "acme-box"},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      # Still refused (the provider call itself), not on the double link.
      assert match?({:error, _}, response)
      refute response_text(response) =~ "already"
    end
  end

  defp refuse(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      401,
      Jason.encode!(%{
        "error" => %{"code" => "unauthorized", "message" => "unable to authenticate"}
      })
    )
  end

  defp response_text({_status, text}), do: text
end
