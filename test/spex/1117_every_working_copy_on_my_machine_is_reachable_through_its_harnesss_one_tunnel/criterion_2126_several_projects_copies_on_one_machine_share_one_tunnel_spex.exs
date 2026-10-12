defmodule CodeMySpecSpex.Story1117.Criterion2126Spex do
  @moduledoc """
  Story 1117 — Every working copy on my machine is reachable through its harness's one tunnel.
  Criterion 2126 — Several projects' copies on one machine share one tunnel.

  Rule: A machine's harness runs exactly one tunnel, however many projects and working copies it serves.

  Every copy's harness being handed the *same* tunnel is what lets the harness
  run one connector for all of them: it keeps one per tunnel, not one per copy.
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
  @dev_tunnel "machine-tunnel-2126"
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

  spex "Several projects' copies on one machine share one tunnel", criterion: 2126 do
    scenario "copies of three projects on one Mac are all carried by one tunnel" do
      given_ "John's harness serves copies of code_my_spec, metric_flow and broken_oaths on his Mac",
             context do
        context = johns_mac(context)

        projects = [
          context.project,
          Fixtures.project_fixture(context.scope, %{name: "metric_flow"}),
          Fixtures.project_fixture(context.scope, %{name: "broken_oaths"})
        ]

        copies =
          projects
          |> Enum.with_index()
          |> Enum.map(fn {project, i} ->
            in_project = in_project(context, project)

            {in_project,
             serving_copy(
               in_project,
               "/workspace/#{project.name}",
               context.mac,
               "http://127.0.0.1:#{41_260 + i}"
             )}
          end)

        {:ok, Map.put(context, :copies, copies)}
      end

      when_ "each of those copies has its address turned on", context do
        responses =
          Enum.map(context.copies, fn {in_project, copy} -> turn_on(in_project, copy) end)

        {:ok, Map.put(context, :responses, responses)}
      end

      then_ "every copy is given an address", context do
        for response <- context.responses do
          refute response.isError,
                 "a serving copy was refused an address: " <> response_text(response)
        end

        {:ok, context}
      end

      then_ "exactly one tunnel exists, and it carries every one of those addresses", context do
        assert [tunnel_id] = Map.keys(tunnels(context.cf)),
               "expected the machine's one tunnel, found: #{inspect(Map.keys(tunnels(context.cf)))}"

        carried = context.cf |> routes(tunnel_id) |> Enum.map(&elem(&1, 0))

        for {_in_project, copy} <- context.copies do
          assert address_host(copy) in carried,
                 "#{address_host(copy)} is not on the machine's tunnel; it carries #{inspect(carried)}"
        end

        {:ok, Map.put(context, :tunnel_id, tunnel_id)}
      end

      then_ "every copy's harness is handed that one tunnel to run", context do
        for {in_project, copy} <- context.copies do
          {reply, _copy} = rejoin(in_project, copy)

          assert %{"tunnel_id" => tunnel_id} = reply.tunnel || %{},
                 "#{copy.root}'s harness was handed no tunnel at all"

          assert tunnel_id == context.tunnel_id,
                 "#{copy.root}'s harness was handed #{tunnel_id}, not the machine's one tunnel"
        end

        {:ok, context}
      end
    end
  end
end
