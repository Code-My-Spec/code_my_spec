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

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Stories.Tools.OffboardWorkingCopy
  alias CodeMySpec.McpServers.Stories.Tools.ShareCopyApp
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
        :ok = Environments.register(context.project.id, context.environment)

        reply = join_working_copy(context, "/workspace/main", "main")

        :ok = CodeMySpecSpex.Fixtures.designate_main(context.scope, reply.working_copy_id)

        :ok =
          Environments.write_file(
            context.environment,
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
        assert main.preview_tunnel_id == @tunnel_id

        {:ok, Map.put(context, :main, main)}
      end

      given_ "a second copy on the same device is sharing that tunnel", context do
        {reply, socket} =
          join_working_copy_socket(context, "/workspace/worktree", "worktree",
            device_id: context.main.device_id
          )

        ref =
          Phoenix.ChannelTest.push(socket, "ensure_app_running_result", %{
            "ref" => "spex-1593-share",
            "status" => "ok",
            "app_status" => "serving",
            "app_url" => "http://127.0.0.1:41593"
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok)

        share_frame = %Frame{
          assigns: %{
            current_scope: %{context.scope | active_working_copy_id: reply.working_copy_id}
          }
        }

        {:reply, share_response, _frame} = ShareCopyApp.execute(%{}, share_frame)
        refute share_response.isError, "setup failed to share the copy in the first place"

        # Drained here, not left for `then_` below — sharing puts a config
        # too, and an `assert_receive` on "put_config" later would otherwise
        # match this setup message rather than offboarding's own.
        assert_receive {:cloudflare, "put_config", _share_ingress}

        {:ok, sibling} = WorkingCopies.fetch(reply.working_copy_id)
        assert sibling.preview_tunnel_id == @tunnel_id

        {:ok, Map.put(context, :sibling_id, sibling.id)}
      end

      when_ "an operator discards that copy", context do
        operator_frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          OffboardWorkingCopy.execute(%{working_copy_id: context.sibling_id}, operator_frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the offboard answers success", context do
        refute context.response.isError,
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

        host = PreviewAddress.host(context.sibling_id)

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
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => [%{"id" => "rec-1593"}]})
  end

  defp cond_response(false, false, true, %{method: "DELETE"} = conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "dns_deleted", conn.request_path})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
  end

  defp cond_response(false, false, true, conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "dns_records"})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1593"}})
  end
end
