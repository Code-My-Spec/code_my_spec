defmodule CodeMySpecSpex.Story966.Criterion8156Spex do
  @moduledoc """
  Story 966 — My app answers on my own server over HTTPS
  Criterion 8156 — UAT stands alone, and prod arrives on its own box when Sam is ready.

  Environments never share a server. Setup provisions UAT first, and
  production gets a box of its own whenever Sam turns it on — which is what
  UAT is for: deploy there until you are ready to go to prod.

  This replaced an earlier criterion that had production *relocating* off a
  shared box. Sharing was tried and abandoned for a documented reason —
  prod-affecting infrastructure changes cannot be validated in a UAT that
  lives on the same machine — so a relocation path would be a route back to a
  configuration already rejected. Turning production on provisions; it never
  migrates.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @uat_only_cassette "hetzner_uat_server_only"
  @prod_added_cassette "hetzner_prod_server_added"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "UAT stands alone, and prod arrives on its own box when Sam is ready" do
    scenario "turning production on adds a server and leaves UAT's alone" do
      given_ "Sam has turned production off and only UAT is set up", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # The options form is `phx-change`, and its params are
        # `options[<key>]`. A submit carrying a `provisioning` map changed
        # nothing at all — the page kept every default and the criterion
        # passed while asserting the opposite of what it says.
        choose_all_setup_options_except(view, [:prod])

        html =
          with_provider_cassette(@uat_only_cassette, fn ->
            view |> element("[data-test='start-setup']") |> render_click()
          end)

        servers = servers_by_environment(html)

        # Anchor: UAT really was provisioned on its own, and production was
        # genuinely absent rather than merely unlisted.
        assert Map.has_key?(servers, "uat"),
               "expected UAT to be provisioned, got #{inspect(servers)}"

        refute Map.has_key?(servers, "prod"),
               "expected no production server while the option is off, got #{inspect(servers)}"

        {:ok,
         context
         |> Map.put(:view, view)
         |> Map.put(:uat_server_before, servers["uat"])}
      end

      when_ "he later turns production on and runs setup again", context do
        context.view
        |> form("[data-test='setup-options-form']", provisioning: %{prod: true})
        |> render_submit()

        html =
          with_provider_cassette(@prod_added_cassette, fn ->
            context.view |> element("[data-test='start-setup']") |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "production is provisioned on a server of its own", context do
        servers = servers_by_environment(context.html)

        assert is_binary(servers["prod"]) and servers["prod"] != "",
               "expected production to have a server of its own, got #{inspect(servers)}"

        refute servers["prod"] == servers["uat"],
               "expected production and UAT never to share a server, both #{inspect(servers["prod"])}"

        {:ok, Map.put(context, :servers, servers)}
      end

      then_ "UAT keeps the server it already had, untouched", context do
        assert context.servers["uat"] == context.uat_server_before,
               "expected UAT's server to be untouched by adding production: before=#{inspect(context.uat_server_before)} after=#{inspect(context.servers["uat"])}"

        {:ok, context}
      end
    end
  end

  defp servers_by_environment(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='environment']")
    |> Enum.reduce(%{}, fn el, acc ->
      env = el |> Floki.attribute("data-environment") |> List.first()
      server = el |> Floki.attribute("data-server") |> List.first()

      case {env, server} do
        {e, s} when is_binary(e) and is_binary(s) and s != "" -> Map.put(acc, e, s)
        _ -> acc
      end
    end)
  end
end
