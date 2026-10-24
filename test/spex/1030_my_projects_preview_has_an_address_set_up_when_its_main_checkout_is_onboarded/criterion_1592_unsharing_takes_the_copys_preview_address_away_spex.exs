defmodule CodeMySpecSpex.Story1030.Criterion1592Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main
  checkout is onboarded.
  Criterion 1592 — Unsharing takes the copy's preview address away.

  Rule: A copy's app gets a preview only when its own agent asks, and only
  once the app is serving.

  `UnshareCopyApp` is the other side of `ShareCopyApp` (criterion 1590):
  dropping the ingress rule that pointed the copy's hostname at its app and
  the DNS record behind it, and clearing the copy's own recorded address —
  see `PreviewTunnel.release/1`. Same onboarding shape as 1590: main holds a
  real tunnel, the sibling shares it, and this criterion is about taking that
  sharing back.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.AppInstances

  import CodeMySpecSpex.WorkingCopyHelpers

  import CodeMySpecSpex.MachineTunnelHelpers,
    only: [configure_persistent_main: 2, report_serving: 3]

  alias Anubis.Server.Frame
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpec.Workspaces.PreviewTunnel

  setup :register_log_in_setup_account
  setup :setup_active_project

  @harness_config ".cms_harness.json"
  @tunnel_id "a11ce000-0000-4000-8000-000000001592"

  spex "Unsharing takes the copy's preview address away", criterion: 1592 do
    scenario "a copy that shared its preview asks to stop sharing it" do
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

        Req.Test.stub(PreviewTunnel, &cloudflare_response(&1, self()))

        Mix.Task.reenable("cms.harness.onboard")
        _report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        assert_receive {:cloudflare, "cfd_tunnel"}
        assert_receive {:cloudflare, "dns_records"}

        {:ok, main} = WorkingCopies.fetch(reply.working_copy_id)

        assert AppInstances.for_working_copy(context.scope, main.id).preview_tunnel_id ==
                 @tunnel_id

        {:ok, Map.put(context, :main, main)}
      end

      given_ "a second copy on the same device is already sharing that tunnel", context do
        {reply, socket} =
          join_working_copy_socket(context, "/workspace/worktree", "worktree",
            device_id: context.main.device_id
          )

        instance = AppInstances.for_working_copy(context.scope, reply.working_copy_id)

        :ok = report_serving(socket, instance.id, "http://127.0.0.1:41592")

        frame = %Frame{
          assigns: %{
            current_scope: %{context.scope | active_working_copy_id: reply.working_copy_id}
          }
        }

        share_response =
          ToolLibrary.run(
            "share_copy_app",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, share_response),
               "setup failed to share the copy in the first place"

        # Drained here, not left for the `then_` below: sharing puts a config
        # too, and an `assert_receive` on "put_config" later would otherwise
        # match this setup message rather than unsharing's own.
        assert_receive {:cloudflare, "put_config", _share_ingress}

        {:ok, sibling} = WorkingCopies.fetch(reply.working_copy_id)

        assert AppInstances.for_working_copy(context.scope, sibling.id).preview_tunnel_id ==
                 @tunnel_id

        {:ok, context |> Map.put(:sibling_id, sibling.id) |> Map.put(:frame, frame)}
      end

      when_ "that copy's own agent asks to stop sharing it", context do
        response =
          ToolLibrary.run(
            "unshare_copy_app",
            %{},
            Map.put(context.frame.assigns, :scope, context.frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it answers success rather than an error", context do
        assert match?({:ok, _}, context.response),
               "unsharing a copy that was actually shared failed. Got: " <>
                 response_text(context.response)

        {:ok, context}
      end

      then_ "the copy's own row no longer holds an address or a tunnel", context do
        {:ok, saved} = WorkingCopies.fetch(context.sibling_id)

        assert AppInstances.for_working_copy(context.scope, saved.id).preview_tunnel_id == nil,
               "the copy still holds a tunnel id after asking to stop sharing"

        assert AppInstances.for_working_copy(context.scope, saved.id).preview_url == nil,
               "the copy still holds an address after asking to stop sharing"

        {:ok, context}
      end

      then_ "its hostname is no longer in the shared tunnel's ingress", context do
        assert_receive {:cloudflare, "put_config", ingress}

        host =
          PreviewAddress.host(AppInstances.for_working_copy(context.scope, context.sibling_id).id)

        refute Enum.any?(ingress, &(&1["hostname"] == host)),
               "the copy's own hostname was still in the tunnel's ingress after unsharing"

        {:ok, context}
      end
    end
  end

  defp cloudflare_response(conn, test_pid) do
    cond_response(
      String.contains?(conn.request_path, "/configurations"),
      String.contains?(conn.request_path, "cfd_tunnel"),
      String.contains?(conn.request_path, "dns_records"),
      conn,
      test_pid
    )
  end

  defp cond_response(true, _cfd_tunnel?, _dns?, %{method: "GET"} = conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "get_config", nil})

    Req.Test.json(conn, %{
      "success" => true,
      "errors" => [],
      "result" => %{"config" => %{"ingress" => []}}
    })
  end

  defp cond_response(true, _cfd_tunnel?, _dns?, conn, test_pid) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    CodeMySpecSpex.Fixtures.notify(
      test_pid,
      {:cloudflare, "put_config", Jason.decode!(body)["config"]["ingress"]}
    )

    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
  end

  defp cond_response(false, true, _dns?, conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "cfd_tunnel"})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => @tunnel_id}})
  end

  defp cond_response(false, false, true, %{method: "GET"} = conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "dns_get", nil})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => [%{"id" => "rec-1592"}]})
  end

  defp cond_response(false, false, true, conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "dns_records"})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1592"}})
  end
end
