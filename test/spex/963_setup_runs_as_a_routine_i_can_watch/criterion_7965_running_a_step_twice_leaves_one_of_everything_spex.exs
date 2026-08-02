defmodule CodeMySpecSpex.Story963.Criterion7965Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7965 — Running a step twice leaves one of everything.

  Steps converge rather than accumulate. Running the server step a second
  time leaves one server per environment and one firewall, and reports
  success — it does
  not error out complaining the resources already exist, and it does not
  create duplicates Sam then pays for.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @create_cassette "963_7965_hetzner_server_create_ok"
  @converge_cassette "hetzner_server_create_idempotent"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "Running a step twice leaves one of everything" do
    scenario "a second run of the server step converges instead of duplicating" do
      given_ "the server step already provisioned a server and a firewall", context do
        view = mount_provisioning(context)

        # Everything the server step needs before it can reach Hetzner, and
        # a teardown registered before anything is made — a recording that
        # fails partway must still not leave a box running.
        tear_down_after(context.scope, [:server])

        # The repository too, so the next recording starts from one that does not
        # exist — a repository carrying an earlier run's commits rejects a fresh
        # push as non-fast-forward (which is 8184's subject, not this one's).
        tear_down_repository(context.project)

        with_provider_cassette(@create_cassette, fn ->
          # Saving a credential proves it with a real call now, so this is a
          # provider interaction and belongs inside the cassette.
          paste_provider_credentials(view)

          view
          |> element("[data-test='setup-step'][data-step='server'] [data-test='run-step']")
          |> render_click()
        end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the server step runs a second time", context do
        with_provider_cassette(@converge_cassette, fn ->
          context.view
          |> element("[data-test='setup-step'][data-step='server'] [data-test='run-step']")
          |> render_click()
        end)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the step reports success rather than an already-exists error", context do
        assert context.html =~ ~r/data-step="server"[^>]*data-state="done"/,
               "expected the repeated run to succeed, not error on existing resources"

        refute context.html =~ ~r/data-step="server"[^>]*data-state="errored"/,
               "expected no already-exists failure on the second run"

        {:ok, context}
      end

      then_ "the record shows one server and one firewall", context do
        resources =
          context.html
          |> Floki.parse_document!()
          # Scoped to the step. The page renders resources twice — under the
          # step that made them and again in the record at the bottom — so an
          # unscoped count reads two renderings as two servers, which is the
          # exact thing under test.
          |> Floki.find(
            "[data-test='setup-step'][data-step='server'] [data-test='provisioned-resource']"
          )
          |> Enum.map(fn el ->
            {el |> Floki.attribute("data-kind") |> List.first(),
             el |> Floki.attribute("data-environment") |> List.first()}
          end)

        # Anchor: resources are recorded at all, so the counts below mean
        # something.
        assert resources != [], "expected the run to record provisioned resources"

        # One server *per environment*, not one server. Each environment gets
        # its own box — that is what makes an environment an environment, and
        # what keeps UAT traffic off production. Idempotence is therefore "no
        # environment gained a second server", not "there is only one server".
        servers_by_environment =
          resources
          |> Enum.filter(fn {kind, _} -> kind == "server" end)
          |> Enum.frequencies_by(fn {_, environment} -> environment end)

        assert servers_by_environment != %{},
               "expected the run to record a server, got #{inspect(resources)}"

        for {environment, count} <- servers_by_environment do
          assert count == 1,
                 "expected exactly one server for #{environment} after two runs, " <>
                   "got #{count} — the re-run duplicated it"
        end

        # The firewall and the ssh key are the project's, shared by every
        # environment, so there is still exactly one of those.
        assert Enum.count(resources, fn {kind, _} -> kind == "firewall" end) == 1,
               "expected exactly one firewall after two runs, got #{inspect(resources)}"

        {:ok, context}
      end
    end
  end
end
