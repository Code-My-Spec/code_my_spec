defmodule CodeMySpecSpex.Story985.Criterion8179Spex do
  @moduledoc """
  Story 985 — My repository exists before anything needs to push
  Criterion 8179 — An existing repository is adopted rather than duplicated.

  Sam already having a repository is an ordinary way in, not an error path.
  Setup adopts it and creates nothing. This is also what makes a retried step
  safe: the second run finds the repository from the first and adopts it
  rather than making a second one.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Repository`.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "github_repo_already_owned"
  @given_cassette "github_repo_first_run_created"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "An existing repository is adopted rather than duplicated" do
    scenario "a repository Sam already owns becomes the project's remote untouched" do
      # Setup ran once and made the repository — which is what its own claim
      # rests on: "the second run finds the repository from the first". A
      # repository that merely happens to exist is criterion 8185's case, and
      # that one stops and asks rather than adopting.
      given_ "setup already created the repository on an earlier run", context do
        view = mount_provisioning(context)

        with_full_cassette @given_cassette do
          view
          |> element("[data-test='setup-step'][data-step='repository'] [data-test='run-step']")
          |> render_click()
        end

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

      then_ "the step reports it adopted rather than created", context do
        repo =
          context.html
          |> Floki.parse_document!()
          # Scoped to the step. The page renders resources twice — once under
          # the step that made them and once in the record at the bottom — and
          # counting across both conflates "two renderings" with "two
          # repositories", which is the thing under test.
          |> Floki.find(
            "[data-test='setup-step'][data-step='repository'] " <>
              "[data-test='provisioned-resource'][data-kind='repository']"
          )

        assert repo != [], "expected the adopted repository to be recorded"

        disposition = repo |> Floki.attribute("data-disposition") |> List.first()

        assert disposition == "adopted",
               "expected the repository to be adopted, got #{inspect(disposition)}"

        {:ok, Map.put(context, :repos, repo)}
      end

      then_ "nothing was created", context do
        assert length(context.repos) == 1,
               "expected adoption to leave exactly one repository, got #{length(context.repos)}"

        refute context.html =~ ~r/data-kind="repository"[^>]*data-disposition="created"/,
               "expected no repository to be created when one was already owned"

        {:ok, context}
      end

      then_ "the step still completes", context do
        assert context.html =~ ~r/data-step="repository"[^>]*data-state="done"/,
               "expected adopting an existing repository to satisfy the step"

        {:ok, context}
      end
    end
  end
end
