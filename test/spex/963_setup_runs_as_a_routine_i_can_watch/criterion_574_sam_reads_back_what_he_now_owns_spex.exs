defmodule CodeMySpecSpex.Story963.Criterion7969Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7969 — Sam reads back what he now owns.

  When setup finishes, Sam can read back each provisioned resource and
  where it lives, and find every one of them in his own provider
  consoles. A routine that provisions infrastructure without telling him
  what it made leaves him unable to audit, bill, or clean up.

  Retargeted onto the console (provisioning-console-step6, unmerged): "the
  setup record" was one page listing everything; the console has no
  equivalent single page — each resource group's own Config tab lists what
  it owns instead. Running each scripted step on its own group's page and
  reading that group's `provisioned-resource` listing tests the same claim
  (every provisioned resource reads back its kind and location) without a
  single page to gather them all on.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  @groups %{
    repository: :repository,
    server: :servers,
    domain: :dns_domain,
    storage: :storage_backups
  }

  spex "Sam reads back what he now owns", criterion: 574 do
    scenario "the record lists each provisioned resource and where it lives" do
      given_ "setup has completed", context do
        # The claim is that the record reads back what the run reported, with
        # each resource's kind and where it lives. What the steps report is the
        # input to that; whether Hetzner really made a box is story 966's
        # claim, and buying one here only made this criterion slower and more
        # fragile.
        context =
          scripted_run(context, %{
            repository: {:ok, [%{kind: "repository", location: "github/sam/his-app"}]},
            server: {:ok, [%{kind: "server", location: "hetzner/49.12.1.1/his-app-prod"}]},
            domain: {:ok, [%{kind: "domain", location: "cloudflare/his-app.com"}]},
            storage: {:ok, [%{kind: "bucket", location: "his-app-prod"}]}
          })

        for {step, group} <- @groups do
          {:ok, view, _html} =
            live(context.conn, "/app/projects/#{context.project.id}/console/resources/#{group}")

          run_console_step(view, step)
        end

        {:ok, context}
      end

      when_ "Sam opens each resource group he just ran", context do
        resources =
          Enum.flat_map(@groups, fn {_step, group} ->
            {:ok, view, _html} =
              live(context.conn, "/app/projects/#{context.project.id}/console/resources/#{group}")

            render(view)
            |> Floki.parse_document!()
            |> Floki.find("[data-test='provisioned-resource']")
          end)

        {:ok, Map.put(context, :resources, resources)}
      end

      then_ "he sees each provisioned resource and where it lives", context do
        resources = context.resources

        # Anchor: the record listed anything at all.
        assert resources != [], "expected the setup record to list provisioned resources"

        for resource <- resources do
          kind = resource |> Floki.attribute("data-kind") |> List.first()
          location = resource |> Floki.attribute("data-location") |> List.first()

          assert is_binary(kind) and kind != "",
                 "expected every recorded resource to name what it is"

          assert is_binary(location) and location != "",
                 "expected #{kind} to record where it lives so Sam can find it in his console"
        end

        {:ok, context}
      end
    end
  end
end
