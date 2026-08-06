defmodule CodeMySpecSpex.Story966.Criterion8005Spex do
  @moduledoc """
  Story 966 — My app answers on my own server over HTTPS
  Criterion 8005 — The deployed image is the one the repo built.

  What runs on the box is traceable to the commit that produced it. The
  deploy pulls the image CI built for that commit rather than building
  locally from whatever happens to be in the working tree — so "what is
  running in production" has an answer Sam can check.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "github_ci_image_published_then_deployed"

  @given_cassette "966_8005_repo_pushed"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :real_working_directory
  setup :connect_providers

  spex "The deployed image is the one the repo built" do
    scenario "the running version is traceable to the commit CI built" do
      given_ "Sam's project is pushed to its remote", context do
        context = stage_deploy(context, :ok)
        view = mount_provisioning(context)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the deploy runs", context do
        html =
          context.view
          |> element("[data-test='setup-step'][data-step='deploy'] [data-test='run-step']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it deployed the image built from that commit", context do
        deployment =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='deployed-version']")

        # Anchor: a deployment was recorded.
        assert deployment != [], "expected the deploy to record what it shipped"

        commit = deployment |> Floki.attribute("data-commit") |> List.first()
        image = deployment |> Floki.attribute("data-image") |> List.first()

        assert is_binary(commit) and commit != "",
               "expected the deployed version to name its commit"

        assert is_binary(image) and image != "",
               "expected the deployed version to name the image it pulled"

        assert String.contains?(image, commit),
               "expected the image tag to carry the commit so the two cannot drift: image=#{inspect(image)} commit=#{inspect(commit)}"

        {:ok, Map.put(context, :deployment, deployment)}
      end

      then_ "the image came from the registry rather than a local build", context do
        source = context.deployment |> Floki.attribute("data-image-source") |> List.first()

        assert source == "registry",
               "expected the deploy to pull CI's image rather than build locally, got #{inspect(source)}"

        {:ok, context}
      end
    end
  end
end
