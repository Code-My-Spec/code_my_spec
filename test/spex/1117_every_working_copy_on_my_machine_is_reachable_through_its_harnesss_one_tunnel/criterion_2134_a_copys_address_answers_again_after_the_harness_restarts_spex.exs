defmodule CodeMySpecSpex.Story1117.Criterion2134Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2134 — A copy's address answers again after the harness restarts.

  Rule: A copy's address survives a restart of its app or of the harness.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.MachineTunnelHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    # The channel is another process, and so is anything it reaches Cloudflare from.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # John's Mac, already running the dev tunnel: dev.codemyspec.com and the
  # astralbi app, as `config/dev.exs` carries them today.
  @dev_tunnel "machine-tunnel-2134"
  @dev_routes [
    {"dev.codemyspec.com", "http://127.0.0.1:4000"},
    {"*.astralbi.com", "http://127.0.0.1:4010"}
  ]

  defp johns_mac(context) do
    cf = cloudflare()
    mac = machine(context)
    existing_tunnel(cf, @dev_tunnel, @dev_routes)

    :ok =
      Fixtures.record_machine_tunnel(context.scope, mac, %{
        tunnel_id: @dev_tunnel,
        tunnel_secret: "c2VjcmV0"
      })

    Map.merge(context, %{cf: cf, mac: mac})
  end

  spex "A copy's address answers again after the harness restarts", criterion: 2134 do
    scenario "the same address answers after a restart, with nobody turning it on again" do
      given_ "a copy's address answers", context do
        context = johns_mac(context)
        copy = serving_copy(context, "/workspace/feature", context.mac, "http://127.0.0.1:41340")
        response = turn_on(context, copy)
        refute response.isError, response_text(response)

        {:ok, Map.merge(context, %{copy: copy, address: address_in(response)})}
      end

      when_ "the harness restarts and the copy's app comes back up", context do
        {reply, copy} = rejoin(context, context.copy)

        ref =
          Phoenix.ChannelTest.push(copy.socket, "ensure_app_running_result", %{
            "ref" => "spex-2134-back",
            "status" => "ok",
            "app_status" => "serving",
            "app_url" => copy.app_url
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok)

        {:ok, Map.put(context, :rejoin_reply, reply)}
      end

      then_ "the same address answers again without anyone sharing it again", context do
        assert shown_address(context, context.copy) == context.address,
               "after the restart the Working Copies page shows no address, or a different one"

        assert {address_host(context.copy), context.copy.app_url} in routes(
                 context.cf,
                 @dev_tunnel
               ),
               "the copy's route is no longer on the machine's tunnel after the restart"

        assert %{"tunnel_id" => @dev_tunnel} = context.rejoin_reply.tunnel || %{},
               "the restarted harness was not handed the tunnel to run again"

        {:ok, context}
      end
    end
  end
end
