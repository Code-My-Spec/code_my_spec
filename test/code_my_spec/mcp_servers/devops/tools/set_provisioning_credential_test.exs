defmodule CodeMySpec.McpServers.Devops.Tools.SetProvisioningCredentialTest do
  @moduledoc """
  An agent's only path to writing a provisioning credential — see issue
  e2a9ed8c: devops_status and run_devops_setup could read and act, but
  nothing could set a pasted secret, so credential-linking was human-in-
  browser-only no matter how agent-drivable the rest of the flow was.

  The Hetzner call `check/2` makes to verify the save is stubbed the same
  way `provisioning/hetzner_test.exs` does — the client was proven against
  the live API there; this pins that a saved token reaches it and a
  verification result comes back, not the client's own HTTP behavior.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpecSpex.TaskResponseHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Devops.Tools.SetProvisioningCredential
  alias CodeMySpec.Provisioning.Hetzner

  defp stub(fun), do: Req.Test.stub(Hetzner, fun)

  defp frame(scope), do: %Frame{assigns: %{current_scope: scope}}

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "execute/2" do
    test "stores a pasted secret and reports the real verification result" do
      scope = full_scope_fixture()
      stub(fn conn -> json(conn, 200, %{"servers" => []}) end)

      assert {:reply, response, _frame} =
               SetProvisioningCredential.execute(
                 %{key: "hetzner_api_token", value: "a-real-looking-token"},
                 frame(scope)
               )

      assert response_text(response) =~ "Saved and verified"
    end

    test "names what the provider rejected rather than saying only invalid" do
      scope = full_scope_fixture()
      stub(fn conn -> json(conn, 403, %{"error" => %{"message" => "forbidden"}}) end)

      assert {:reply, response, _frame} =
               SetProvisioningCredential.execute(
                 %{key: "hetzner_api_token", value: "read-only-token"},
                 frame(scope)
               )

      text = response_text(response)
      assert text =~ "Saved"
      assert text =~ "rejected"
    end

    test "refuses an OAuth connection credential — nothing to paste" do
      scope = full_scope_fixture()

      assert {:reply, response, _frame} =
               SetProvisioningCredential.execute(
                 %{key: "cloudflare_token", value: "irrelevant"},
                 frame(scope)
               )

      assert response_text(response) =~ "OAuth connection"
    end

    test "refuses an unknown credential key by name" do
      scope = full_scope_fixture()

      assert {:reply, response, _frame} =
               SetProvisioningCredential.execute(
                 %{key: "not_a_real_credential", value: "x"},
                 frame(scope)
               )

      text = response_text(response)
      assert text =~ "No credential named"
      assert text =~ "hetzner_api_token"
    end

    test "refuses when the frame carries no scope" do
      assert {:reply, response, _frame} =
               SetProvisioningCredential.execute(
                 %{key: "hetzner_api_token", value: "x"},
                 %Frame{assigns: %{}}
               )

      refute response_text(response) =~ "Saved"
    end
  end
end
