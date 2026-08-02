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

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "github_repo_already_owned"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An existing repository is adopted rather than duplicated" do
    scenario "a repository Sam already owns becomes the project's remote untouched" do
      given_ "Sam is on the setup status page and already owns the repository", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the repository step runs", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='repository'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the step reports it adopted rather than created", context do
        repo =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='repository']")

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
