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

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Stories.Tools.ShareCopyApp
  alias CodeMySpec.McpServers.Stories.Tools.UnshareCopyApp
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

      given_ "a second copy on the same device is already sharing that tunnel", context do
        {reply, socket} =
          join_working_copy_socket(context, "/workspace/worktree", "worktree",
            device_id: context.main.device_id
          )

        ref =
          Phoenix.ChannelTest.push(socket, "ensure_app_running_result", %{
            "ref" => "spex-1592-share",
            "status" => "ok",
            "app_status" => "serving",
            "app_url" => "http://127.0.0.1:41592"
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok)

        frame = %Frame{
          assigns: %{
            current_scope: %{context.scope | active_working_copy_id: reply.working_copy_id}
          }
        }

        {:reply, share_response, _frame} = ShareCopyApp.execute(%{}, frame)
        refute share_response.isError, "setup failed to share the copy in the first place"

        # Drained here, not left for the `then_` below: sharing puts a config
        # too, and an `assert_receive` on "put_config" later would otherwise
        # match this setup message rather than unsharing's own.
        assert_receive {:cloudflare, "put_config", _share_ingress}

        {:ok, sibling} = WorkingCopies.fetch(reply.working_copy_id)
        assert sibling.preview_tunnel_id == @tunnel_id

        {:ok, context |> Map.put(:sibling_id, sibling.id) |> Map.put(:frame, frame)}
      end

      when_ "that copy's own agent asks to stop sharing it", context do
        {:reply, response, _frame} = UnshareCopyApp.execute(%{}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it answers success rather than an error", context do
        refute context.response.isError,
               "unsharing a copy that was actually shared failed. Got: " <>
                 response_text(context.response)

        {:ok, context}
      end

      then_ "the copy's own row no longer holds an address or a tunnel", context do
        {:ok, saved} = WorkingCopies.fetch(context.sibling_id)

        assert saved.preview_tunnel_id == nil,
               "the copy still holds a tunnel id after asking to stop sharing"

        assert saved.preview_url == nil,
               "the copy still holds an address after asking to stop sharing"

        {:ok, context}
      end

      then_ "its hostname is no longer in the shared tunnel's ingress", context do
        assert_receive {:cloudflare, "put_config", ingress}

        host = PreviewAddress.host(context.sibling_id)

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
