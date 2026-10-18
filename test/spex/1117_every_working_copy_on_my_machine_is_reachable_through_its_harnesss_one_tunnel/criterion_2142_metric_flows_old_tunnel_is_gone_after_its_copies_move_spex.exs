defmodule CodeMySpecSpex.Story1117.Criterion2142Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2142 — Metric Flow's old tunnel is gone after its copies move.

  Rule: Once a project's copies have moved, its old tunnel is deleted from Cloudflare along with its stored credentials.
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
  @dev_tunnel "machine-tunnel-2142"
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

  spex "Metric Flow's old tunnel is gone after its copies move", criterion: 2142 do
    scenario "moving Metric Flow onto the machine tunnel removes its old one" do
      given_ "Metric Flow's main copy still holds its old per-project tunnel", context do
        context = johns_mac(context)

        metric_flow =
          in_project(context, Fixtures.project_fixture(context.scope, %{name: "metric_flow"}))

        copy =
          serving_copy(
            metric_flow,
            "/workspace/metric_flow",
            context.mac,
            "http://127.0.0.1:4070"
          )

        :ok = Fixtures.designate_main(metric_flow.scope, copy.id)

        existing_tunnel(context.cf, "metric-flow-old", [
          {address_host(copy), "http://127.0.0.1:4070"}
        ])

        :ok =
          Fixtures.record_project_tunnel(metric_flow.scope, copy.id, %{
            tunnel_id: "metric-flow-old",
            tunnel_secret: "c2VjcmV0"
          })

        {:ok, Map.merge(context, %{metric_flow: metric_flow, copy: copy})}
      end

      when_ "Metric Flow's copies move onto the machine tunnel", context do
        {:ok, Map.put(context, :response, turn_on(context.metric_flow, context.copy))}
      end

      then_ "Metric Flow's old tunnel no longer exists", context do
        assert match?({:ok, _}, context.response), response_text(context.response)

        assert "metric-flow-old" in deleted_tunnels(context.cf),
               "Metric Flow's old tunnel is still in the Cloudflare account"

        assert tunnel_carrying(context.cf, address_host(context.copy)) == @dev_tunnel,
               "Metric Flow's address is not on the machine tunnel"

        {:ok, context}
      end

      then_ "no working copy still holds its credentials", context do
        {reply, _copy} = rejoin(context.metric_flow, context.copy)

        assert %{"tunnel_id" => @dev_tunnel} = reply.tunnel || %{},
               "Metric Flow's harness is still handed its old tunnel to run"

        {:ok, context}
      end
    end
  end
end
