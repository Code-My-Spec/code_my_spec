defmodule CodeMySpecSpex.Story966.Criterion8047Spex do
  @moduledoc """
  Story 966 — My app answers on my own server over HTTPS
  Criterion 8047 — Production moves to its own box when Sam outgrows sharing.

  Setup starts both environments on one server — cheapest for a founder
  with no users — and that is only acceptable because production can move
  to its own box later without being rebuilt. Setup provisions the new
  server and relocates production; Sam does not reconfigure the
  environment from scratch to get there.

  This is the criterion that earns the one-box start. Without it, sharing
  a box is a decision Sam cannot walk back.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @shared_cassette "hetzner_single_box_both_environments"
  @relocate_cassette "hetzner_prod_relocated_to_own_box"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Production moves to its own box when Sam outgrows sharing" do
    scenario "production relocates to a new server without being rebuilt" do
      given_ "both environments share one server", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        before =
          ReqCassette.with_cassette(@shared_cassette, [mode: :replay], fn ->
            view |> element("[data-test='start-setup']") |> render_click()
          end)

        servers = server_ids(before)

        # Anchor: the shared start actually happened — one server carrying
        # both environments.
        assert MapSet.size(servers) == 1,
               "expected both environments on one server to begin with, got #{inspect(MapSet.to_list(servers))}"

        {:ok,
         context
         |> Map.put(:view, view)
         |> Map.put(:before_servers, servers)
         |> Map.put(:before, before)}
      end

      when_ "Sam decides production needs its own server", context do
        html =
          ReqCassette.with_cassette(@relocate_cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='environment'][data-environment='prod'] [data-test='relocate']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "setup provisions the new server and moves production onto it", context do
        parsed = Floki.parse_document!(context.html)

        prod_server =
          parsed
          |> Floki.find("[data-test='environment'][data-environment='prod']")
          |> Floki.attribute("data-server")
          |> List.first()

        uat_server =
          parsed
          |> Floki.find("[data-test='environment'][data-environment='uat']")
          |> Floki.attribute("data-server")
          |> List.first()

        assert is_binary(prod_server) and prod_server != "",
               "expected production to name the server it now runs on"

        refute prod_server == uat_server,
               "expected production to have moved off the shared box, both still on #{inspect(prod_server)}"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "he did not reconfigure the environment from scratch", context do
        # The environment keeps its identity across the move — same hostname,
        # same secrets, same database. A relocation that made Sam re-enter
        # any of that would be a rebuild wearing a different name.
        preserved =
          context.parsed
          |> Floki.find("[data-test='environment'][data-environment='prod']")
          |> Floki.attribute("data-config-preserved")
          |> List.first()

        assert preserved == "true",
               "expected the environment's configuration to survive the move rather than being rebuilt"

        refute context.html =~ ~r/data-environment="prod"[^>]*data-state="not_started"/,
               "expected production not to be reset to an unprovisioned state by the move"

        {:ok, context}
      end
    end
  end

  defp server_ids(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='environment']")
    |> Enum.map(&(Floki.attribute(&1, "data-server") |> List.first()))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> MapSet.new()
  end
end
