defmodule CodeMySpecSpex.Story1030.Criterion1590Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main
  checkout is onboarded.
  Criterion 1590 — Asking to share a serving copy's app gives it a preview
  address.

  Rule: A copy's app gets a preview only when its own agent asks, and only
  once the app is serving.

  `ShareCopyApp` is the surface an agent actually calls to ask — not
  `PreviewTunnel.ensure/1` directly, which criteria 1586/1587 already
  exercise for the sharing decision itself (a same-device sibling reuses
  main's tunnel rather than provisioning one of its own). What this criterion
  adds is the tool boundary around that decision: an agent asks for its own
  copy, and only gets an address once there is something real to point it at.

  Same onboarding shape as 1586: main is onboarded for real
  (`cms.harness.onboard`) so it holds a genuine tunnel, and the sibling joins
  the same device and reports its own app serving over its own channel —
  the harness's real "I am up" report, not a fixture standing in for it.
  Cloudflare is stubbed for the same reason 1586 stubs it: the sharing
  decision is what is under test, not Cloudflare's remote configuration API.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Stories.Tools.ShareCopyApp
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewTunnel

  setup :register_log_in_setup_account
  setup :setup_active_project

  @harness_config ".cms_harness.json"
  @tunnel_id "a11ce000-0000-4000-8000-000000001590"

  spex "Asking to share a serving copy's app gives it a preview address",
       criterion: 1590 do
    scenario "a copy on main's device asks for its own preview once it is serving" do
      given_ "main is onboarded and holds a tunnel of its own", context do
        :ok = Environments.register(context.project.id, context.environment)

        reply = join_working_copy(context, "/workspace/main", "main")

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

      given_ "a second copy on the same device reports its own app serving", context do
        {reply, socket} =
          join_working_copy_socket(context, "/workspace/worktree", "worktree",
            device_id: context.main.device_id
          )

        ref =
          Phoenix.ChannelTest.push(socket, "ensure_app_running_result", %{
            "ref" => "spex-1590",
            "status" => "ok",
            "app_status" => "serving",
            "app_url" => "http://127.0.0.1:41590"
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok)

        {:ok, Map.put(context, :sibling_id, reply.working_copy_id)}
      end

      when_ "that copy's own agent asks to share it", context do
        frame = %Frame{
          assigns: %{current_scope: %{context.scope | active_working_copy_id: context.sibling_id}}
        }

        {:reply, response, _frame} = ShareCopyApp.execute(%{}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it is handed a public address rather than nothing", context do
        refute context.response.isError,
               "the ask was refused even though the copy was serving. Got: " <>
                 response_text(context.response)

        assert response_text(context.response) =~ "https://",
               "the reply named no address for the caller to actually reach it at"

        {:ok, context}
      end

      then_ "the copy's own row records the address it was given", context do
        {:ok, saved} = WorkingCopies.fetch(context.sibling_id)

        assert saved.preview_tunnel_id == @tunnel_id,
               "the copy shares main's tunnel — a tunnel of its own would mean it was " <>
                 "provisioned one instead of being handed the existing one"

        assert saved.preview_url,
               "the tool answered success but recorded no address for this copy"

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
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"config" => %{"ingress" => []}}})
  end

  defp cond_response(true, _cfd_tunnel?, conn, test_pid) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "put_config", Jason.decode!(body)["config"]["ingress"]})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{}})
  end

  defp cond_response(false, true, conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "cfd_tunnel"})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => @tunnel_id}})
  end

  defp cond_response(false, false, conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "dns_records"})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1590"}})
  end
end
