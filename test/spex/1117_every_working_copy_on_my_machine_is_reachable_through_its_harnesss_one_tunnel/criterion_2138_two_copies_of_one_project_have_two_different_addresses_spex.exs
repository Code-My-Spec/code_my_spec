defmodule CodeMySpecSpex.Story1117.Criterion2138Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2138 — Two copies of one project have two different addresses.

  Rule: Each working copy has its own public address, which is turned on and off per copy.
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
  @dev_tunnel "machine-tunnel-2138"
  @dev_routes [
    {"dev.codemyspec.com", "http://127.0.0.1:4000"},
    {"*.astralbi.com", "http://127.0.0.1:4010"}
  ]

  defp johns_mac(context) do
    cf = cloudflare()
    mac = machine()
    existing_tunnel(cf, @dev_tunnel, @dev_routes)

    :ok =
      Fixtures.record_machine_tunnel(context.scope, mac, %{
        tunnel_id: @dev_tunnel,
        tunnel_secret: "c2VjcmV0"
      })

    Map.merge(context, %{cf: cf, mac: mac})
  end

  spex "Two copies of one project have two different addresses", criterion: 2138 do
    scenario "main and maintenance each answer at an address of their own" do
      given_ "the main copy and the maintenance copy of code_my_spec both have their addresses turned on",
             context do
        context = johns_mac(context)

        main =
          serving_copy(context, "/workspace/code_my_spec", context.mac, "http://127.0.0.1:4000")

        :ok = Fixtures.designate_main(context.scope, main.id)

        maintenance =
          serving_copy(context, "/workspace/maintenance", context.mac, "http://127.0.0.1:60584")

        for copy <- [main, maintenance] do
          response = turn_on(context, copy)

          refute response.isError,
                 "#{copy.root} was refused an address: " <> response_text(response)
        end

        {:ok, Map.merge(context, %{main: main, maintenance: maintenance})}
      end

      when_ "John opens each copy's preview address", context do
        {:ok,
         Map.merge(context, %{
           main_address: shown_address(context, context.main),
           maintenance_address: shown_address(context, context.maintenance)
         })}
      end

      then_ "each address shows that copy's own app", context do
        assert context.main_address, "the Working Copies page shows main no address"
        assert context.maintenance_address, "the Working Copies page shows maintenance no address"
        refute context.main_address == context.maintenance_address

        routes = routes(context.cf, @dev_tunnel)
        assert {host(context.main_address), context.main.app_url} in routes
        assert {host(context.maintenance_address), context.maintenance.app_url} in routes

        {:ok, context}
      end
    end
  end
end
