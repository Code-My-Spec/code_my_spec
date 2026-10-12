defmodule CodeMySpecSpex.Story1117.Criterion2135Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2135 — A cloud copy is reached through its own machine's tunnel.

  Rule: A copy on another machine is never reached through this machine's tunnel.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.MachineTunnelHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  # Channels, and the Working Copies page, are both on the cloud endpoint.
  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    # The channel is another process, and so is anything it reaches Cloudflare from.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # John's Mac, already running the dev tunnel: dev.codemyspec.com and the
  # astralbi app, as `config/dev.exs` carries them today.
  @dev_tunnel "machine-tunnel-2135"
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

  spex "A cloud copy is reached through its own machine's tunnel", criterion: 2135 do
    scenario "each machine's copy is carried by that machine's tunnel" do
      given_ "John has a copy on his Mac and a copy on a cloud box", context do
        context = johns_mac(context)
        cloud = machine(context)
        on_mac = serving_copy(context, "/workspace/mac", context.mac, "http://127.0.0.1:41351")
        on_cloud = serving_copy(context, "/workspace/cloud", cloud, "http://127.0.0.1:41352")

        {:ok, Map.merge(context, %{on_mac: on_mac, on_cloud: on_cloud})}
      end

      when_ "both copies have addresses", context do
        {:ok,
         Map.put(context, :responses, [
           turn_on(context, context.on_mac),
           turn_on(context, context.on_cloud)
         ])}
      end

      then_ "the cloud copy's address is served by the cloud box's tunnel, not the Mac's",
            context do
        for response <- context.responses, do: refute(response.isError, response_text(response))

        mac_tunnel = tunnel_carrying(context.cf, address_host(context.on_mac))
        cloud_tunnel = tunnel_carrying(context.cf, address_host(context.on_cloud))

        assert mac_tunnel == @dev_tunnel
        assert cloud_tunnel, "the cloud copy's address is on no tunnel at all"

        refute cloud_tunnel == mac_tunnel,
               "the cloud copy's address is on the Mac's tunnel, whose connector cannot reach the cloud box"

        {reply, _copy} = rejoin(context, context.on_cloud)

        assert %{"tunnel_id" => ^cloud_tunnel} = reply.tunnel || %{},
               "the cloud box's harness was not handed its own machine's tunnel"

        {:ok, context}
      end
    end
  end
end
