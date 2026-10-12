defmodule CodeMySpecSpex.Story1117.Criterion2140Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2140 — A copy whose app is not running cannot have its address turned on.

  Rule: Each working copy has its own public address, which is turned on and off per copy.
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
  @dev_tunnel "machine-tunnel-2140"
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

  spex "A copy whose app is not running cannot have its address turned on", criterion: 2140 do
    scenario "turning on a copy with no app serving is refused" do
      given_ "a copy has no app serving", context do
        context = johns_mac(context)
        {:ok, Map.put(context, :copy, idle_copy(context, "/workspace/idle", context.mac))}
      end

      when_ "John turns its address on", context do
        {:ok, Map.put(context, :response, turn_on(context, context.copy))}
      end

      then_ "he is told the copy's app is not running", context do
        assert context.response.isError, "a copy with no app serving was given an address"

        assert response_text(context.response) =~ ~r/not (running|serving)/i,
               "the refusal does not say the app is not running: " <>
                 response_text(context.response)

        {:ok, context}
      end

      then_ "the address stays off", context do
        assert is_nil(shown_address(context, context.copy))

        refute address_host(context.copy) in Enum.map(
                 routes(context.cf, @dev_tunnel),
                 &elem(&1, 0)
               ),
               "a route was written for a copy that was refused"

        {:ok, context}
      end
    end
  end
end
