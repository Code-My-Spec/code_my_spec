defmodule CodeMySpecSpex.Story1117.Criterion2137Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2137 — A Cloudflare failure during offboarding keeps the copy's record.

  Rule: Offboarding a copy leaves no route or DNS record behind for its address.
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
  @dev_tunnel "machine-tunnel-2137"
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

  spex "A Cloudflare failure during offboarding keeps the copy's record", criterion: 2137 do
    scenario "Cloudflare refuses while a copy with an address is being offboarded" do
      given_ "a copy has an address on the tunnel", context do
        context = johns_mac(context)
        copy = serving_copy(context, "/workspace/feature", context.mac, "http://127.0.0.1:41370")
        response = turn_on(context, copy)
        refute response.isError, response_text(response)

        {:ok, Map.merge(context, %{copy: copy, address: address_in(response)})}
      end

      given_ "Cloudflare refuses the request to remove a copy's route", context do
        cloudflare_fails(context.cf)
        {:ok, context}
      end

      when_ "the copy is offboarded", context do
        {:ok, Map.put(context, :response, offboard(context, context.copy))}
      end

      then_ "the offboard is refused", context do
        assert context.response.isError,
               "the offboard went ahead although Cloudflare refused to remove the copy's route"

        {:ok, context}
      end

      then_ "the copy keeps its record, so the leftover route can still be found and removed",
            context do
        assert shown_address(context, context.copy) == context.address,
               "the copy, or the address it held, is gone from the Working Copies page — the one " <>
                 "record of a route Cloudflare may still be serving"

        {:ok, context}
      end
    end
  end
end
