defmodule CodeMySpecSpex.Story1117.Criterion2139Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2139 — Turning a copy's address off makes it unreachable.

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
  @dev_tunnel "machine-tunnel-2139"
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

  spex "Turning a copy's address off makes it unreachable", criterion: 2139 do
    scenario "a copy whose address is turned off is no longer reachable at it" do
      given_ "a copy's address is on and answering", context do
        context = johns_mac(context)
        copy = serving_copy(context, "/workspace/feature", context.mac, "http://127.0.0.1:41390")
        response = turn_on(context, copy)
        refute response.isError, response_text(response)

        {:ok, Map.put(context, :copy, copy)}
      end

      when_ "John turns that copy's address off", context do
        {:ok, Map.put(context, :response, turn_off(context, context.copy))}
      end

      then_ "the address no longer reaches the copy's app", context do
        refute context.response.isError, response_text(context.response)

        refute address_host(context.copy) in Enum.map(
                 routes(context.cf, @dev_tunnel),
                 &elem(&1, 0)
               ),
               "the copy's route is still on the tunnel after its address was turned off"

        assert is_nil(shown_address(context, context.copy)),
               "the Working Copies page still shows an address for a copy turned off"

        {:ok, context}
      end
    end
  end
end
