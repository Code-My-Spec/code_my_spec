defmodule CodeMySpecSpex.Story985.Criterion8178Spex do
  @moduledoc """
  Story 985 — My repository exists before anything needs to push
  Criterion 8178 — One repository, carrying the project's docs.

  A new project gets one repository, and its docs live inside it. Not two
  repositories, and not a submodule: `.code_my_spec/` is part of the working
  tree the harness reads, so a clone that lacks it is a project the harness
  cannot work on. Splitting the docs out is a deliberate later operation, not
  the default a new project is born with.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Repository`.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "github_repo_docs_single"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "One repository, carrying the project's docs" do
    scenario "the step creates a single repository and records it as the remote" do
      given_ "Sam is on the setup status page with GitHub connected", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the repository step runs", context do
        html =
          with_full_cassette @cassette do
            context.view
            |> element("[data-test='setup-step'][data-step='repository'] [data-test='run-step']")
            |> render_click()
          end

        {:ok, Map.put(context, :html, html)}
      end

      then_ "exactly one repository is recorded", context do
        repos =
          context.html
          |> Floki.parse_document!()
          # Scoped to the step — the page renders each resource twice (under
          # the step and in the record at the bottom), so an unscoped count
          # sees one repository as two.
          |> Floki.find(
            "[data-test='setup-step'][data-step='repository'] " <>
              "[data-test='provisioned-resource'][data-kind='repository']"
          )

        assert length(repos) == 1,
               "expected one repository, got #{length(repos)}"

        {:ok, Map.put(context, :repos, repos)}
      end

      then_ "no second repository is created for docs", context do
        refute context.html =~ ~r/data-kind="repository"[^>]*data-role="docs"/,
               "expected the docs to live inside the one repository, not in a second one"

        {:ok, context}
      end

      then_ "the project records that repository as its remote", context do
        remote =
          context.repos
          |> List.first()
          |> Floki.attribute("data-location")
          |> List.first()

        assert is_binary(remote) and remote != "",
               "expected the repository's location recorded so the harness has a remote to push to"

        {:ok, context}
      end
    end
  end
end
