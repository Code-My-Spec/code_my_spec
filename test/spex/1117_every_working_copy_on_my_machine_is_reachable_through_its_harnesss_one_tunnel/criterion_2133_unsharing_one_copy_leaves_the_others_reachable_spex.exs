defmodule CodeMySpecSpex.Story1117.Criterion2133Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2133 — Unsharing one copy leaves the others reachable.

  Rule: Giving a copy an address, or taking it away, does not interrupt any other address on the tunnel.
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
  @dev_tunnel "machine-tunnel-2133"
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

  spex "Unsharing one copy leaves the others reachable", criterion: 2133 do
    scenario "taking one copy's address away leaves the other's in place" do
      given_ "two copies have addresses on the tunnel", context do
        context = johns_mac(context)
        first = serving_copy(context, "/workspace/first", context.mac, "http://127.0.0.1:41331")
        second = serving_copy(context, "/workspace/second", context.mac, "http://127.0.0.1:41332")

        for copy <- [first, second] do
          response = turn_on(context, copy)

          assert match?({:ok, _}, response),
                 "setup failed to give #{copy.root} an address: " <> response_text(response)
        end

        {:ok, Map.merge(context, %{first: first, second: second})}
      end

      when_ "one copy's address is taken away", context do
        {:ok, Map.put(context, :response, turn_off(context, context.first))}
      end

      then_ "the other copy's address still answers", context do
        assert match?({:ok, _}, context.response), response_text(context.response)

        carried = context.cf |> routes(@dev_tunnel) |> Enum.map(&elem(&1, 0))

        assert address_host(context.second) in carried,
               "taking the first copy's address away removed the second copy's too"

        refute address_host(context.first) in carried,
               "the first copy's address is still on the tunnel after being taken away"

        assert dns_tunnel(context.cf, address_host(context.second)) == @dev_tunnel

        {:ok, context}
      end
    end
  end
end
