defmodule CodeMySpecSpex.Story985.Criterion8185Spex do
  @moduledoc """
  Story 985 — My repository exists before anything needs to push
  Criterion 8185 — A colliding name is named, and Sam chooses.

  When the name setup wants is already taken on Sam's account, it says so and
  offers him the choice: adopt that repository, or use a different name. It
  does neither on his behalf.

  Both automatic behaviours are wrong in different ways. Pushing into the
  existing repository could scribble on an unrelated project. Silently
  inventing a suffixed name leaves Sam with a repository he did not choose and
  cannot easily find — and the project form's existing `-docs` suffix habit is
  exactly the reflex this criterion exists to prevent.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Repository`.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "github_repo_name_taken"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A colliding name is named, and Sam chooses" do
    scenario "the collision is surfaced with both choices and neither is taken automatically" do
      given_ "Sam is on the setup status page and already has a repository by that name", context do

        # The repository is already there — that is the premise. It used to be
        # there because an earlier run left it, which made this pass on a dirty
        # account and fail on a clean one.
        existing_repository(context.project)

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

      then_ "setup says the name is taken", context do
        text =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='setup-step'][data-step='repository']")
          |> Floki.text()

        assert text =~ ~r/taken|already exists/i,
               "expected the collision to be named, got: #{inspect(String.slice(text, 0, 200))}"

        {:ok, context}
      end

      then_ "both choices are offered", context do
        assert has_element?(context.view, "[data-test='adopt-existing-repository']"),
               "expected an option to adopt the existing repository"

        assert has_element?(context.view, "[data-test='choose-another-name']"),
               "expected an option to use a different name"

        {:ok, context}
      end

      then_ "neither choice was taken automatically", context do
        refute context.html =~ ~r/data-step="repository"[^>]*data-state="done"/,
               "expected setup to wait for Sam rather than resolving the collision itself"

        refute context.html =~ ~r/data-kind="repository"[^>]*data-disposition="created"/,
               "expected no suffixed name to be invented on Sam's behalf"

        {:ok, context}
      end
    end
  end
end
