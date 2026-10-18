defmodule CodeMySpecSpex.Story1030.Criterion1594Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main
  checkout is onboarded.
  Criterion 1594 — A Cloudflare failure while taking the preview down
  refuses the offboard and keeps the copy's record.

  Rule: Offboarding a copy takes its preview down with it.

  A copy's row is the only place that remembers it ever held a shared
  hostname. If releasing the preview fails, deleting the row anyway would
  erase that one record while the ingress rule or the DNS record may still
  be live on Cloudflare's side — a hostname nothing will ever remember to
  release. So a Cloudflare failure refuses the offboard loudly, and the row
  stays exactly where it was, rather than being deleted regardless (the
  opposite of criterion 1593's happy path).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewTunnel

  setup :register_log_in_setup_account
  setup :setup_active_project

  @harness_config ".cms_harness.json"
  @tunnel_id "a11ce000-0000-4000-8000-000000001594"

  spex "A Cloudflare failure while taking the preview down refuses the offboard and keeps the copy's record",
    criterion: 1594 do
    scenario "Cloudflare fails while a shared copy is being discarded" do
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
            "ref" => "spex-1594-share",
            "status" => "ok",
            "app_status" => "serving",
            "app_url" => "http://127.0.0.1:41594"
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok)

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

        {:ok, sibling} = WorkingCopies.fetch(reply.working_copy_id)
        assert sibling.preview_tunnel_id == @tunnel_id

        {:ok, context |> Map.put(:sibling_id, sibling.id) |> Map.put(:sibling, sibling)}
      end

      given_ "Cloudflare starts failing every request", context do
        Req.Test.stub(PreviewTunnel, &cloudflare_failure_response/1)

        {:ok, context}
      end

      when_ "an operator discards that copy", context do
        operator_frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "offboard_working_copy",
            %{working_copy_id: context.sibling_id},
            Map.put(operator_frame.assigns, :scope, operator_frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the offboard is refused rather than proceeding anyway", context do
        assert match?({:error, _}, context.response),
               "the offboard succeeded even though releasing the shared preview failed. " <>
                 "Got: " <> response_text(context.response)

        {:ok, context}
      end

      then_ "the copy's row, and what it remembers about its preview, is unchanged", context do
        assert {:ok, still_there} = WorkingCopies.fetch(context.sibling_id)

        assert still_there.preview_tunnel_id == context.sibling.preview_tunnel_id,
               "the row was cleared even though releasing the preview failed — the one " <>
                 "record of a hostname Cloudflare may still be serving is now gone"

        assert still_there.preview_url == context.sibling.preview_url

        {:ok, context}
      end
    end
  end

  defp cloudflare_response(conn, test_pid) do
    cond_response(
      String.contains?(conn.request_path, "/configurations"),
      String.contains?(conn.request_path, "cfd_tunnel"),
      conn,
      test_pid
    )
  end

  defp cond_response(true, _cfd_tunnel?, %{method: "GET"} = conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "get_config", nil})

    Req.Test.json(conn, %{
      "success" => true,
      "errors" => [],
      "result" => %{"config" => %{"ingress" => []}}
    })
  end

  defp cond_response(true, _cfd_tunnel?, conn, test_pid) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    CodeMySpecSpex.Fixtures.notify(
      test_pid,
      {:cloudflare, "put_config", Jason.decode!(body)["config"]["ingress"]}
    )

    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
  end

  defp cond_response(false, true, conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "cfd_tunnel"})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => @tunnel_id}})
  end

  defp cond_response(false, false, conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "dns_records"})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1594"}})
  end

  # What matters is that *some* step `release/1` takes fails, not which — an
  # unreachable account fails the ingress read, the ingress write and the DNS
  # lookup identically.
  defp cloudflare_failure_response(conn) do
    Req.Test.json(conn, %{
      "success" => false,
      "errors" => [%{"code" => 1000, "message" => "down"}]
    })
  end
end
