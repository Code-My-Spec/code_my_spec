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

  Retargeted onto the console (provisioning-console-step6, unmerged): there
  is no `start-setup` whole-run to run UAT through and run again for prod —
  each step is run directly via `run_console_step/2` on its own resource
  group's page instead (`repository` once, then `secrets`/`server` per
  environment on `servers`). The environment listing this reads
  (`[data-test='environment']`, from `EnvironmentsForm`) is unchanged, now
  on `/console/settings`.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # `secrets` seeds each environment's encrypted env into `envs/<env>.enc.env`,
  # which the project generator lays down — so both halves are needed: a real
  # directory to generate into, and the generate itself. Without the directory
  # the generated files have nowhere to land; without the generate the files
  # are absent and sops exits 100 on a file it will not create.
  setup :fake_working_directory
  setup :fake_providers
  setup :account_access_key
  setup :confirm_new_servers

  spex "UAT stands alone, and prod arrives on its own box when Sam is ready", criterion: 602 do
    scenario "turning production on adds a server and leaves UAT's alone" do
      given_ "Sam has turned production off and only UAT is set up", context do
        # Before the page mounts. The LiveView reads the project once, at mount;
        # claiming the repository afterwards updates the row but not the socket,
        # so the step still saw a repository belonging to nobody and paused.
        own_repository(context.project)

        {:ok, deploys_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys")

        # Before setup runs, or it stops at its second step. `secrets` seeds
        # each environment's encrypted env, and sops will not create the file
        # it is told to write into — `envs/uat.enc.env` is scaffolding the
        # project generator lays down (story 970, `DeployArtifacts`). Without
        # it the step exits 100 with "cannot operate on non-existent file" and
        # every step after it stays not_started, which reads as "UAT was never
        # provisioned" — the thing this criterion asserts.
        deploys_view |> element("[data-test='generate-project']") |> render_click()

        # Production is off because the project has no production environment,
        # not because a checkbox is unticked — there is no `prod` option on the
        # setup form, and there never was. Environments are rows; the steps fan
        # out over whichever ones exist.
        only_environments(context.scope, ["uat"])

        tear_down_after(context.scope, [:server])
        tear_down_repository(context.project)

        {:ok, credentials_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/credentials")

        paste_provider_credentials(credentials_view)

        {:ok, repository_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/repository")

        run_console_step(repository_view, :repository)

        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/servers?env=uat"
          )

        for step <- [:secrets, :server], do: run_console_step(view, step)

        {:ok, settings_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/settings")

        html = render(settings_view)
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
        {:ok, settings_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/settings")

        settings_view
        |> form("[data-test='add-environment-form']", environment: %{name: "prod"})
        |> render_submit()

        {:ok, prod_view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/servers?env=prod"
          )

        for step <- [:secrets, :server], do: run_console_step(prod_view, step)

        {:ok, settings_view2, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/settings")

        {:ok, Map.put(context, :html, render(settings_view2))}
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

    # No step markup on this page anymore (it's /console/settings, not a
    # resource-detail page) — the environment listing is the whole of what's
    # worth printing here now.
    "environments: #{environments}"
  end

  defp servers_by_environment(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='environment']")
    |> Enum.reduce(%{}, fn el, acc ->
      env = el |> Floki.attribute("data-environment") |> List.first()
      server = el |> Floki.attribute("data-server") |> List.first()

      put_server(acc, env, server)
    end)
  end

  # An environment row renders whether or not a server was provisioned, so the
  # attribute is present and empty for one that was not. Treating that as a
  # server is what would let "prod exists" pass on a row that only proves prod
  # was listed — which is exactly what this criterion refutes.
  defp put_server(acc, env, server)
       when is_binary(env) and is_binary(server) and server != "",
       do: Map.put(acc, env, server)

  defp put_server(acc, _env, _server), do: acc
end
