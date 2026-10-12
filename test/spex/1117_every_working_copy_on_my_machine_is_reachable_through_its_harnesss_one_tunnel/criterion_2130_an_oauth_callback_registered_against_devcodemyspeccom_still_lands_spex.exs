defmodule CodeMySpecSpex.Story1117.Criterion2130Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2130 — An OAuth callback registered against dev.codemyspec.com still lands.

  Rule: dev.codemyspec.com keeps its hostname when it moves onto the harness's tunnel.

  The OAuth round trip itself is not driven here: what an OAuth provider holds is
  a hostname, and the claim is that the hostname keeps resolving to the same app.
  So the evidence is the route and the DNS record, which are what Cloudflare would
  use to deliver the callback.
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
  @dev_tunnel "machine-tunnel-2130"
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

  spex "An OAuth callback registered against dev.codemyspec.com still lands", criterion: 2130 do
    scenario "dev.codemyspec.com is still where the app answers once the harness carries it" do
      given_ "John's OAuth app has its callback registered at https://dev.codemyspec.com",
             context do
        context = johns_mac(context)

        {:ok,
         Map.put(
           context,
           :copy,
           serving_copy(context, "/workspace/code_my_spec", context.mac, "http://127.0.0.1:4000")
         )}
      end

      when_ "dev.codemyspec.com is carried by the harness's tunnel", context do
        {:ok, Map.put(context, :response, turn_on(context, context.copy))}
      end

      then_ "the copy's address and dev.codemyspec.com are on the same tunnel", context do
        refute context.response.isError, response_text(context.response)

        assert tunnel_carrying(context.cf, address_host(context.copy)) == @dev_tunnel,
               "the copy's address was put on another tunnel, not the machine's"

        {:ok, context}
      end

      then_ "dev.codemyspec.com still resolves to that tunnel and still reaches the app on 4000",
            context do
        assert {"dev.codemyspec.com", "http://127.0.0.1:4000"} in routes(context.cf, @dev_tunnel),
               "dev.codemyspec.com's route was dropped or changed, so an OAuth callback registered " <>
                 "against it would not land"

        assert dns_tunnel(context.cf, "dev.codemyspec.com") == @dev_tunnel,
               "dev.codemyspec.com's DNS record no longer points at the tunnel carrying it"

        {:ok, context}
      end
    end
  end
end
