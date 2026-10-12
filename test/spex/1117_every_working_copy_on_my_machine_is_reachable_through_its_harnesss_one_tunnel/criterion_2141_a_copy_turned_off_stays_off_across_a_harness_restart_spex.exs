defmodule CodeMySpecSpex.Story1117.Criterion2141Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2141 — A copy turned off stays off across a harness restart.

  Rule: A copy's address stays on or off as set until someone changes it.
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
  @dev_tunnel "machine-tunnel-2141"
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

  spex "A copy turned off stays off across a harness restart", criterion: 2141 do
    scenario "a restart does not turn a copy's address back on" do
      given_ "John turned a copy's address off", context do
        context = johns_mac(context)
        copy = serving_copy(context, "/workspace/feature", context.mac, "http://127.0.0.1:41410")
        on = turn_on(context, copy)
        refute on.isError, response_text(on)
        off = turn_off(context, copy)
        refute off.isError, response_text(off)

        {:ok, Map.put(context, :copy, copy)}
      end

      when_ "the harness restarts and the copy's app comes back up", context do
        {_reply, copy} = rejoin(context, context.copy)

        ref =
          Phoenix.ChannelTest.push(copy.socket, "ensure_app_running_result", %{
            "ref" => "spex-2141-back",
            "status" => "ok",
            "app_status" => "serving",
            "app_url" => copy.app_url
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok)
        {:ok, context}
      end

      then_ "the copy's address is still off", context do
        assert is_nil(shown_address(context, context.copy)),
               "the restart turned the copy's address back on"

        refute address_host(context.copy) in Enum.map(
                 routes(context.cf, @dev_tunnel),
                 &elem(&1, 0)
               ),
               "the restart put the copy's route back on the tunnel"

        {:ok, context}
      end
    end
  end
end
