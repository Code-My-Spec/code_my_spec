defmodule CodeMySpecSpex.Story985.Criterion8180Spex do
  @moduledoc """
  Story 985 — My repository exists before anything needs to push
  Criterion 8180 — The repository belongs to Sam, not to the platform.

  The repository is created under Sam's own account through his own GitHub App
  installation. Nothing is held on the platform's side. A repository the
  platform owns is one Sam cannot take with him, which defeats the point of
  him owning his own infrastructure.

  The account may be personal or an organisation — both are Sam's. What must
  never appear is a repository owned by the platform.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Repository`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "github_repo_create_ok"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The repository belongs to Sam, not to the platform" do
    scenario "the created repository is owned by Sam's own account" do
      given_ "Sam is on the setup status page with GitHub connected", context do
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

      then_ "the repository is recorded as owned by the user", context do
        repo =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='repository']")

        # Anchor: a repository was recorded at all, so the refute below is not
        # passing against an empty page.
        assert repo != [], "expected the run to record the provisioned repository"

        owner = repo |> Floki.attribute("data-owner") |> List.first()

        assert owner == "user",
               "expected the repository to be owned by Sam, got #{inspect(owner)}"

        {:ok, context}
      end

      then_ "nothing about it is held on the platform's side", context do
        refute context.html =~ ~r/data-kind="repository"[^>]*data-owner="platform"/,
               "expected no part of the repository to be held by the platform"

        {:ok, context}
      end
    end
  end
end
