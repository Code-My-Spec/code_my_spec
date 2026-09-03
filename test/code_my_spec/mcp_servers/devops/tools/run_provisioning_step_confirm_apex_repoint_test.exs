defmodule CodeMySpec.McpServers.Devops.Tools.RunProvisioningStepConfirmApexRepointTest do
  @moduledoc """
  `Steps.apex_repoint/4` refuses to move a live apex without
  `opts[:confirm_apex_repoint]` — `RunProvisioningStep` never exposed a
  parameter to supply it, so the only way to say yes was
  `ProvisioningLive`'s own "confirm_apex_repoint" button. An agent driving
  devops through this tool instead of a human clicking that button had no
  way to say yes: every retry re-detected the live apex and paused again,
  identically, with no error and no explanation for why nothing progressed.

  Driven end to end through the real `Cloudflare` and `Dns` HTTP clients
  (both support an `Application`-config `:plug` override) rather than the
  `Steps.run/3` opts `apex_repoint_test.exs` injects directly — those opts
  (`:zone`, `:dns_records`, `:resolver`, `:write_dns_record`) have no route
  through this tool's params, which is exactly the gap being closed. `async:
  false`: both stubs are process-global `Application` config, the same
  reason `domain_step_test.exs` and `teardown_apex_test.exs` are.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Devops.Tools.RunProvisioningStep
  alias CodeMySpec.Provisioning.{Cloudflare, Dns, EnvironmentRepository}

  @apex "example.com"
  @zone_id "z1"
  @old_ip "172.64.80.1"
  @new_ip "5.161.1.1"

  setup do
    scope = full_scope_fixture()

    {:ok, project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{domain: @apex})

    scope = %{scope | active_project: project}
    {:ok, _} = EnvironmentRepository.put(scope, "prod", %{host: @apex, ip: @new_ip})

    stub_cloudflare()
    stub_dns()

    %{scope: scope, project: project}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp cf_ok(result), do: %{"success" => true, "errors" => [], "result" => result}

  # The zone, the one existing A record (pointing at the OLD address), and
  # the write endpoint the repoint would use once confirmed.
  defp stub_cloudflare do
    test_pid = self()

    Application.put_env(:code_my_spec, Cloudflare,
      api_token: "test-token",
      plug: fn
        %{method: "GET", request_path: "/client/v4/zones"} = conn ->
          json(conn, 200, cf_ok([%{"id" => @zone_id, "name" => @apex}]))

        %{method: "GET", request_path: "/client/v4/zones/" <> _} = conn ->
          json(
            conn,
            200,
            cf_ok([%{"id" => "rec1", "name" => @apex, "type" => "A", "content" => @old_ip}])
          )

        %{method: "PUT", request_path: "/client/v4/zones/" <> rest} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          payload = Jason.decode!(body)
          send(test_pid, {:wrote, rest, payload["content"]})

          json(
            conn,
            200,
            cf_ok(%{"id" => "rec1", "name" => @apex, "type" => "A", "content" => payload["content"]})
          )
      end
    )

    on_exit(fn -> Application.delete_env(:code_my_spec, Cloudflare) end)
  end

  # `Dns.resolution_status/3` prefers the zone's own nameservers, but
  # `stubbed_resolver?/0` reads this same config key and falls back to the
  # DNS-over-HTTPS path the moment it is set — dns.google is queried first
  # and the reduce halts there, so cloudflare-dns.com never needs a branch.
  defp stub_dns do
    Application.put_env(:code_my_spec, Dns,
      plug: fn %{request_path: "/resolve"} = conn ->
        json(conn, 200, %{"Answer" => [%{"data" => @new_ip}]})
      end
    )

    on_exit(fn -> Application.delete_env(:code_my_spec, Dns) end)
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end

  describe "execute/2 for the dns step" do
    test "pauses on a live apex without confirm_apex_repoint, and writes nothing", %{
      scope: scope
    } do
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               RunProvisioningStep.execute(%{step: "dns"}, frame)

      text = response_text(response)
      assert text =~ "is paused:"
      assert text =~ @old_ip
      assert text =~ @new_ip
      assert text =~ "confirm to repoint it"

      refute_received {:wrote, _rest, _content}
    end

    test "repoints the apex when confirm_apex_repoint is true", %{scope: scope} do
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{step: "dns", confirm_apex_repoint: true}
      assert {:reply, response, ^frame} = RunProvisioningStep.execute(params, frame)

      refute response_text(response) =~ "confirm to repoint it",
             "confirm_apex_repoint: true must not still pause on the same guard"

      assert_received {:wrote, "z1/dns_records/rec1", @new_ip},
                       "expected the confirmed run to actually write the apex, not merely stop pausing"
    end
  end
end
