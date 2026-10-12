defmodule CodeMySpecSpex.Story1117.Criterion2131Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2131 — The astralbi.com app keeps answering.

  Rule: Other hostnames the machine already serves keep routing after the move.
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
  @dev_tunnel "machine-tunnel-2131"
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

  spex "The astralbi.com app keeps answering", criterion: 2131 do
    scenario "the astralbi route survives a copy joining the machine's tunnel" do
      given_ "the machine serves *.astralbi.com to the app on port 4010", context do
        context = johns_mac(context)

        {:ok,
         Map.put(
           context,
           :copy,
           serving_copy(context, "/workspace/code_my_spec", context.mac, "http://127.0.0.1:41310")
         )}
      end

      when_ "the machine's addresses move onto the harness's tunnel", context do
        {:ok, Map.put(context, :response, turn_on(context, context.copy))}
      end

      then_ "a request to an astralbi.com hostname still reaches that app", context do
        refute context.response.isError, response_text(context.response)

        assert {"*.astralbi.com", "http://127.0.0.1:4010"} in routes(context.cf, @dev_tunnel),
               "the astralbi route was dropped when the machine's tunnel took on the copy's address"

        assert tunnel_carrying(context.cf, address_host(context.copy)) == @dev_tunnel,
               "the copy's address went onto a tunnel of its own instead of the machine's"

        {:ok, context}
      end
    end
  end
end
