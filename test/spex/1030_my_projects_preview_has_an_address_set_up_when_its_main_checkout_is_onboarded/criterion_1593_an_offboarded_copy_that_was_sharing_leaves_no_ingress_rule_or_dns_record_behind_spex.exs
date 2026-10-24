defmodule CodeMySpecSpex.Story1030.Criterion1593Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main
  checkout is onboarded.
  Criterion 1593 — An offboarded copy that was sharing leaves no ingress
  rule or DNS record behind.

  Rule: Offboarding a copy takes its preview down with it.

  A copy's row is the only place that remembers it ever held a shared
  hostname. Once it is gone there is nothing left to clean the ingress rule
  or the DNS record up with — so releasing the preview has to happen before
  the row does, not after. `OffboardWorkingCopy` is the real surface an agent
  calls to discard a working copy; this is what it does to one that was
  sharing.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.AppInstances

  import CodeMySpecSpex.WorkingCopyHelpers

  import CodeMySpecSpex.MachineTunnelHelpers,
    only: [configure_persistent_main: 2, report_serving: 3, offboard: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpec.Workspaces.PreviewTunnel

  setup :register_log_in_setup_account
  setup :setup_active_project

  @harness_config ".cms_harness.json"
  @tunnel_id "a11ce000-0000-4000-8000-000000001593"

  spex "An offboarded copy that was sharing leaves no ingress rule or DNS record behind",
    criterion: 1593 do
    scenario "a copy sharing main's tunnel is discarded" do
      given_ "main is onboarded and holds a tunnel of its own", context do
        :ok = ExecutionContexts.register(context.project.id, context.execution_context)

        reply = join_working_copy(context, "/workspace/main", "main")

        :ok = CodeMySpecSpex.Fixtures.designate_main(context.scope, reply.working_copy_id)
        :ok = configure_persistent_main(context.scope, reply.working_copy_id)

        :ok =
          ExecutionContexts.write_file(
            context.execution_context,
            @harness_config,
            Jason.encode!(
              %{working_copy_id: reply.working_copy_id, project_id: context.project.id},
              pretty: true
            )
          )

        test_pid = self()
        tunnel_config = start_supervised!({Agent, fn -> [] end})

        Req.Test.stub(PreviewTunnel, fn conn ->
          cloudflare_response(conn, test_pid, tunnel_config)
        end)

        Mix.Task.reenable("cms.harness.onboard")
        _report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        assert_receive {:cloudflare, "cfd_tunnel"}
        assert_receive {:cloudflare, "dns_records"}
        drain_cloudflare_notifications()

        {:ok, main} = WorkingCopies.fetch(reply.working_copy_id)

        assert AppInstances.for_working_copy(context.scope, main.id).preview_tunnel_id ==
                 @tunnel_id

        {:ok, Map.put(context, :main, main)}
      end

      given_ "a second copy on the same device is sharing that tunnel", context do
        {reply, socket} =
          join_working_copy_socket(context, "/workspace/worktree", "worktree",
            device_id: context.main.device_id
          )

        instance = AppInstances.for_working_copy(context.scope, reply.working_copy_id)

        :ok = report_serving(socket, instance.id, "http://127.0.0.1:41593")

        share_frame = %Frame{
          assigns: %{
            current_scope: %{context.scope | active_working_copy_id: reply.working_copy_id}
          }
        }

        share_response =
          ToolLibrary.run(
            "share_copy_app",
            %{},
            Map.put(share_frame.assigns, :scope, share_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, share_response),
               "setup failed to share the copy in the first place"

        # Drained here, not left for `then_` below — sharing puts a config
        # too, and an `assert_receive` on "put_config" later would otherwise
        # match this setup message rather than offboarding's own.
        assert_receive {:cloudflare, "put_config", _share_ingress}

        {:ok, sibling} = WorkingCopies.fetch(reply.working_copy_id)

        assert AppInstances.for_working_copy(context.scope, sibling.id).preview_tunnel_id ==
                 @tunnel_id

        sibling = Map.merge(sibling, %{socket: socket, instance_id: instance.id})
        {:ok, Map.merge(context, %{sibling_id: sibling.id, sibling: sibling})}
      end

      when_ "an operator discards that copy", context do
        response = offboard(context, context.sibling)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the offboard answers success", context do
        assert match?({:ok, _}, context.response),
               "discarding a copy that was sharing its preview failed. Got: " <>
                 response_text(context.response)

        {:ok, context}
      end

      then_ "the copy's row is gone", context do
        assert {:error, :not_found} = WorkingCopies.fetch(context.sibling_id)

        {:ok, context}
      end

      then_ "its hostname is no longer in the shared tunnel's ingress", context do
        assert_receive {:cloudflare, "put_config", ingress}

        host = PreviewAddress.host(context.sibling.instance_id)

        refute Enum.any?(ingress, &(&1["hostname"] == host)),
               "the copy's own hostname was still in the tunnel's ingress after it was offboarded"

        {:ok, context}
      end

      then_ "its DNS record was deleted", context do
        assert_receive {:cloudflare, "dns_deleted", _path}

        {:ok, context}
      end
    end
  end

  defp cloudflare_response(conn, test_pid, tunnel_config) do
    cond_response(
      String.contains?(conn.request_path, "/configurations"),
      String.contains?(conn.request_path, "cfd_tunnel"),
      String.contains?(conn.request_path, "dns_records"),
      conn,
      test_pid,
      tunnel_config
    )
  end

  defp drain_cloudflare_notifications do
    receive do
      {:cloudflare, _event, _payload} -> drain_cloudflare_notifications()
    after
      0 -> :ok
    end
  end

  defp cond_response(true, _cfd_tunnel?, _dns?, %{method: "GET"} = conn, test_pid, tunnel_config) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "get_config", nil})

    ingress = Agent.get(tunnel_config, & &1)

    Req.Test.json(conn, %{
      "success" => true,
      "errors" => [],
      "result" => %{"config" => %{"ingress" => ingress}}
    })
  end

  defp cond_response(true, _cfd_tunnel?, _dns?, conn, test_pid, tunnel_config) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    ingress = Jason.decode!(body)["config"]["ingress"]

    Agent.update(tunnel_config, fn _existing -> ingress end)

    CodeMySpecSpex.Fixtures.notify(
      test_pid,
      {:cloudflare, "put_config", ingress}
    )

    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
  end

  defp cond_response(false, true, _dns?, conn, test_pid, _tunnel_config) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "cfd_tunnel"})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => @tunnel_id}})
  end

  defp cond_response(false, false, true, %{method: "GET"} = conn, test_pid, _tunnel_config) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "dns_get", nil})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => [%{"id" => "rec-1593"}]})
  end

  defp cond_response(false, false, true, %{method: "DELETE"} = conn, test_pid, _tunnel_config) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "dns_deleted", conn.request_path})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
  end

  defp cond_response(false, false, true, conn, test_pid, _tunnel_config) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "dns_records"})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1593"}})
  end
end
