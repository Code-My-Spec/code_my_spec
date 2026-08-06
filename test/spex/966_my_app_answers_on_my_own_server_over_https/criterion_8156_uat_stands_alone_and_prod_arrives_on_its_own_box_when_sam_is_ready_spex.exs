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
  @given_cassette "966_8156_credentials"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "UAT stands alone, and prod arrives on its own box when Sam is ready" do
    scenario "turning production on adds a server and leaves UAT's alone" do
      given_ "Sam has turned production off and only UAT is set up", context do
        # Before the page mounts. The LiveView reads the project once, at mount;
        # claiming the repository afterwards updates the row but not the socket,
        # so the step still saw a repository belonging to nobody and paused.
        own_repository(context.project)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # The options form is `phx-change`, and its params are
        # `options[<key>]`. A submit carrying a `provisioning` map changed
        # nothing at all — the page kept every default and the criterion
        # passed while asserting the opposite of what it says.
        # Production is off because the project has no production environment,
        # not because a checkbox is unticked — there is no `prod` option on the
        # setup form, and there never was. Environments are rows; the steps fan
        # out over whichever ones exist.
        only_environments(context.scope, ["uat"])

        tear_down_after(context.scope, [:server])
        tear_down_repository(context.project)

        with_provider_cassette(@given_cassette, fn ->
          paste_provider_credentials(view)
        end)

        html =
          with_full_cassette @uat_only_cassette do
            view |> element("[data-test='start-setup']") |> render_click()

            # The click starts the run and returns; the step transitions
            # arrive afterwards, so reading what `render_click/1` handed back
            # shows the page as it was *before* anything ran — every step
            # not_started, which reads as "nothing was provisioned".
            await_provisioning(view)
          end

        servers = servers_by_environment(html)

        # Anchor: UAT really was provisioned on its own, and production was
        # genuinely absent rather than merely unlisted.
        assert Map.has_key?(servers, "uat"),
               "expected UAT to be provisioned, got #{inspect(servers)}. " <> diagnose(html)

        refute Map.has_key?(servers, "prod"),
               "expected no production server while the option is off, got #{inspect(servers)}"

        {:ok,
         context
         |> Map.put(:view, view)
         |> Map.put(:uat_server_before, servers["uat"])}
      end

      when_ "he later turns production on and runs setup again", context do
        # Adding the environment, because that is what turning production on
        # is here — there is no `prod` checkbox, and the steps fan out over
        # whichever environment rows exist.
        context.view
        |> form("[data-test='add-environment-form']", environment: %{name: "prod"})
        |> render_submit()

        html =
          with_full_cassette @prod_added_cassette do
            context.view |> element("[data-test='start-setup']") |> render_click()

            # Waiting for production's server specifically. "Nothing is
            # running" cannot distinguish this run finishing from the previous
            # one having finished, and the previous one halted — so that wait
            # returns the page as it was before this run wrote anything.
            await_environment_server(context.view, "prod")
          end

        {:ok, Map.put(context, :html, html)}
      end

      then_ "production is provisioned on a server of its own", context do
        servers = servers_by_environment(context.html)

        assert is_binary(servers["prod"]) and servers["prod"] != "",
               "expected production to have a server of its own, got #{inspect(servers)}. " <>
                 diagnose(context.html)

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

  # What the page actually said, for when an assertion fails and the interesting
  # part is which step stopped and what each environment thinks it is running on.
  defp diagnose(html) do
    parsed = Floki.parse_document!(html)

    environments =
      parsed
      |> Floki.find("[data-test='environment']")
      |> Enum.map_join(" | ", fn e ->
        name = e |> Floki.attribute("data-environment") |> List.first()
        server = e |> Floki.attribute("data-server") |> List.first()
        "#{name}=#{inspect(server)}"
      end)

    steps =
      parsed
      |> Floki.find("[data-test='setup-step']")
      |> Enum.map_join(", ", fn s ->
        name = s |> Floki.attribute("data-step") |> List.first()
        state = s |> Floki.attribute("data-state") |> List.first()

        if state in ["errored", "paused"] do
          detail = s |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.slice(0, 160)
          "#{name}=#{state} (#{detail})"
        else
          "#{name}=#{state}"
        end
      end)

    "environments: #{environments}. steps: #{steps}"
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
