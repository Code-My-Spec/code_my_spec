defmodule CodeMySpecSpex.Story1030.Criterion1587Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main
  checkout is onboarded.
  Criterion 1587 — A copy on a different device never shares another
  device's tunnel.

  Rule: sharing a tunnel across copies only holds where its own reasoning
  holds — every connector attached to it has to be able to reach every
  ingress rule's target, which is true for two ports on one machine and
  false across two. A copy that finds no same-device sibling gets a plain
  refusal rather than something that looks provisioned and silently cannot
  be reached, exactly as criterion 1586 gets a share.

  Exercised the same way 1586 is, and for the same reason (see that spec's
  moduledoc): `WorkingCopies.tunnel_sibling/1` is what `PreviewTunnel.ensure/1`
  asks, and a fresh device from `join_working_copy`'s own fixture is a
  different device from main's by construction — no two harnesses announcing
  independently ever collide on one.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.Workspaces.PreviewTunnel

  setup :register_log_in_setup_account
  setup :setup_active_project

  @harness_config ".cms_harness.json"
  @tunnel_id "a11ce000-0000-4000-8000-000000001587"

  # `refute_receive` waits its whole window by construction, so this is a cost
  # and not a race to win. It is sound to keep it short: the refusal it asserts
  # the absence of was reached synchronously, so there is nothing still in
  # flight by the time this runs. Pinned explicitly because 100 is short enough
  # to be a coin flip under a loaded gate (`3c8ab289`).
  @absence_timeout 250

  spex "A copy on a different device never shares another device's tunnel",
    criterion: 1587 do
    scenario "a copy on a machine of its own asks for a preview" do
      given_ "main is onboarded, on its own device, and holds a tunnel", context do
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

        test_pid = self()
        Req.Test.stub(PreviewTunnel, &cloudflare_response(&1, test_pid))

        Mix.Task.reenable("cms.harness.onboard")
        _report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        assert_receive {:cloudflare, "cfd_tunnel"}
        assert_receive {:cloudflare, "dns_records"}

        {:ok, main} = WorkingCopies.fetch(reply.working_copy_id)
        assert main.preview_tunnel_id == @tunnel_id

        {:ok, Map.put(context, :main, main)}
      end

      when_ "a copy on a different machine reports its own app serving, and asks for its preview",
            context do
        {reply, socket} = join_working_copy_socket(context, "/workspace/elsewhere", "elsewhere")

        {:ok, precheck} = WorkingCopies.fetch(reply.working_copy_id)

        refute precheck.device_id == context.main.device_id,
               "the fixture that mints a fresh device for a join with no device_id " <>
                 "given put this copy on main's own machine — this criterion is not " <>
                 "exercising what it claims to"

        ref =
          Phoenix.ChannelTest.push(socket, "ensure_app_running_result", %{
            "ref" => "spex-1587",
            "status" => "ok",
            "app_status" => "serving",
            "app_url" => "http://127.0.0.1:51234"
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok)

        {:ok, elsewhere} = WorkingCopies.fetch(reply.working_copy_id)
        result = PreviewTunnel.ensure(elsewhere)

        {:ok, context |> Map.put(:elsewhere_id, elsewhere.id) |> Map.put(:result, result)}
      end

      then_ "it is refused rather than handed a tunnel it cannot reach", context do
        assert {:error, :no_tunnel_on_this_device} = context.result,
               "a copy on a machine of its own either shared a tunnel none of its " <>
                 "connectors are attached to, or provisioned one silently — both are " <>
                 "worse than the plain refusal this criterion expects. Got: " <>
                 inspect(context.result)

        {:ok, context}
      end

      then_ "nothing was recorded and no ingress rule was written for it", context do
        {:ok, saved} = WorkingCopies.fetch(context.elsewhere_id)

        assert saved.preview_tunnel_id == nil,
               "the copy holds a tunnel id despite being refused one"

        refute_receive {:cloudflare, _},
                       @absence_timeout,
                       "Cloudflare was reached for a copy this criterion says should " <>
                         "never share — nothing should have been asked of it at all"

        {:ok, context}
      end
    end
  end

  defp cloudflare_response(conn, test_pid),
    do: cfd_tunnel_response(String.contains?(conn.request_path, "cfd_tunnel"), conn, test_pid)

  defp cfd_tunnel_response(true, conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "cfd_tunnel"})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => @tunnel_id}})
  end

  defp cfd_tunnel_response(false, conn, test_pid) do
    CodeMySpecSpex.Fixtures.notify(test_pid, {:cloudflare, "dns_records"})
    Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-1587"}})
  end
end
