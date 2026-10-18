defmodule CodeMySpecSpex.Story1117.Criterion2136Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2136 — An offboarded copy's address stops resolving.

  Rule: Offboarding a copy leaves no route or DNS record behind for its address.
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
  @dev_tunnel "machine-tunnel-2136"
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

  spex "An offboarded copy's address stops resolving", criterion: 2136 do
    scenario "offboarding takes the copy's route and DNS record with it" do
      given_ "a copy has an address on the tunnel", context do
        context = johns_mac(context)
        copy = serving_copy(context, "/workspace/feature", context.mac, "http://127.0.0.1:41360")
        response = turn_on(context, copy)
        assert match?({:ok, _}, response), response_text(response)

        {:ok, Map.put(context, :copy, copy)}
      end

      when_ "the copy is offboarded", context do
        {:ok, Map.put(context, :response, offboard(context, context.copy))}
      end

      then_ "its address has no route on the tunnel and no DNS record", context do
        assert match?({:ok, _}, context.response), response_text(context.response)

        refute address_host(context.copy) in Enum.map(
                 routes(context.cf, @dev_tunnel),
                 &elem(&1, 0)
               ),
               "the offboarded copy's route is still on the machine's tunnel"

        assert is_nil(dns_tunnel(context.cf, address_host(context.copy))),
               "the offboarded copy's DNS record is still there"

        assert {"dev.codemyspec.com", "http://127.0.0.1:4000"} in routes(context.cf, @dev_tunnel),
               "offboarding one copy took dev.codemyspec.com off the tunnel"

        {:ok, context}
      end
    end
  end
end
