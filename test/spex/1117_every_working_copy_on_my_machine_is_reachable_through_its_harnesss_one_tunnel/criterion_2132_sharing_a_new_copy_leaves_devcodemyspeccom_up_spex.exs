defmodule CodeMySpecSpex.Story1117.Criterion2132Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2132 — Sharing a new copy leaves dev.codemyspec.com up.

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
  @dev_tunnel "machine-tunnel-2132"
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

  spex "Sharing a new copy leaves dev.codemyspec.com up", criterion: 2132 do
    scenario "dev.codemyspec.com is on the tunnel through every change a new copy makes" do
      given_ "dev.codemyspec.com is answering through the harness's tunnel", context do
        context = johns_mac(context)

        {:ok,
         Map.put(
           context,
           :copy,
           serving_copy(context, "/workspace/feature", context.mac, "http://127.0.0.1:41320")
         )}
      end

      when_ "another copy is given an address", context do
        {:ok, Map.put(context, :response, turn_on(context, context.copy))}
      end

      then_ "dev.codemyspec.com answers throughout without an interruption", context do
        refute context.response.isError, response_text(context.response)

        history = ingress_history(context.cf, @dev_tunnel)
        assert history != [], "the copy's address was never written to the machine's tunnel"

        for ingress <- history do
          assert Enum.any?(ingress, &(&1["hostname"] == "dev.codemyspec.com")),
                 "one write to the tunnel left dev.codemyspec.com off it: #{inspect(ingress)}"
        end

        {:ok, context}
      end

      then_ "the tunnel the harness runs is the same one it ran before", context do
        {reply, _copy} = rejoin(context, context.copy)

        assert %{"tunnel_id" => @dev_tunnel} = reply.tunnel || %{},
               "the harness was handed a different tunnel, so its connector — dev.codemyspec.com's " <>
                 "with it — had to be replaced"

        {:ok, context}
      end
    end
  end
end
