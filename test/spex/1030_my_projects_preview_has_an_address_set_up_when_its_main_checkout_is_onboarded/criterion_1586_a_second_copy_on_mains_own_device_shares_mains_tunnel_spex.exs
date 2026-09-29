defmodule CodeMySpecSpex.Story1030.Criterion1586Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main
  checkout is onboarded.
  Criterion 1586 — A second copy on main's own device shares main's tunnel.

  Rule: Every connector attached to a tunnel has to be able to satisfy every
  one of its ingress rules — Cloudflare has no notion of which connector is
  near which hostname's target, it hands the request to whichever connector
  answers. That is sound for two copies on one machine: either one's
  `cloudflared` can dial `http://localhost:<the other's port>` just fine,
  because both ports exist on the same box. So a copy on main's own device
  shares main's tunnel — its own hostname, added to the same tunnel's ingress
  — rather than provisioning a second tunnel nothing needs.

  ## Why main is onboarded through the real task and the sibling is not

  `mix cms.harness.onboard` ties one run to one filesystem root — story
  1030's other criteria (1046, 1051) exercise it exactly once per spec for
  that reason. A second real onboarding run, against a second root, is what
  production actually does for the sibling; standing one up inside one
  spec's sandboxed environment is infrastructure this suite does not yet
  have. The sibling is instead brought onto the harness the way `join_working_copy`
  already stands for onboarding elsewhere in this story's own suite, and its
  preview is asked for through `PreviewTunnel.ensure/1` directly — the exact
  call `provision_preview/3` makes from inside the real task, and the
  component this story names as its own (`CodeMySpec.Workspaces.PreviewTunnel`).

  ## Cloudflare is stubbed

  Same reasoning as 1046: the surface under test is the sharing decision, not
  Cloudflare's remote configuration API. `config/test.exs` pins this client's
  plug so a forgotten stub raises rather than reaching a real zone.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewAddress
  alias CodeMySpec.Workspaces.PreviewTunnel

  setup :register_log_in_setup_account
  setup :setup_active_project

  @harness_config ".cms_harness.json"
  @tunnel_id "a11ce000-0000-4000-8000-000000001586"

  spex "A second copy on main's own device shares main's tunnel", criterion: 1586 do
    scenario "a copy on main's device onboards once its own app is serving" do
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

        assert_receive {:cloudflare, "cfd_tunnel", _}

        {:ok, main} = WorkingCopies.fetch(reply.working_copy_id)
        assert main.preview_tunnel_id == @tunnel_id

        {:ok, Map.put(context, :main, main)}
      end

      when_ "a second copy on the same device reports its own app serving, and asks for its preview",
            context do
        {reply, socket} =
          join_working_copy_socket(context, "/workspace/worktree", "worktree",
            device_id: context.main.device_id
          )

        ref =
          Phoenix.ChannelTest.push(socket, "ensure_app_running_result", %{
            "ref" => "spex-1586",
            "status" => "ok",
            "app_status" => "serving",
            "app_url" => "http://127.0.0.1:41234"
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok)

        {:ok, sibling} = WorkingCopies.fetch(reply.working_copy_id)
        result = PreviewTunnel.ensure(sibling)

        {:ok, context |> Map.put(:sibling_id, sibling.id) |> Map.put(:result, result)}
      end

      then_ "it is handed main's own tunnel, not a new one", context do
        assert {:ok, credentials} = context.result

        assert credentials.tunnel_id == @tunnel_id,
               "the sibling got a tunnel of its own rather than sharing main's — a " <>
                 "second connector nothing needs, and a real record in the account " <>
                 "this criterion exists to avoid creating."

        {:ok, saved} = WorkingCopies.fetch(context.sibling_id)
        assert saved.preview_tunnel_id == @tunnel_id
        assert saved.preview_url, "the sibling recorded no address of its own"

        {:ok, context}
      end

      then_ "its own hostname was added to the shared tunnel's ingress", context do
        assert_receive {:cloudflare, "put_config", ingress}

        host = PreviewAddress.host(context.sibling_id)
        rule = Enum.find(ingress, &(&1["hostname"] == host))

        assert rule,
               "the sibling's hostname never reached the tunnel's ingress list, so " <>
                 "cloudflared has nothing telling it to route that name anywhere"

        assert rule["service"] == "http://127.0.0.1:41234"

        assert List.last(ingress) == %{"service" => "http_status:404"},
               "cloudflared refuses a config whose last rule names a host"

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
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "cfd_tunnel", nil})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => @tunnel_id}})
  end

  defp cond_response(false, false, conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "dns_records", nil})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1586"}})
  end
end
