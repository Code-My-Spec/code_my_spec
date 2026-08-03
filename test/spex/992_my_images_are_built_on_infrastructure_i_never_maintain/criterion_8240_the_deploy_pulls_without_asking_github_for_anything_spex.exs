defmodule CodeMySpecSpex.Story992.Criterion8240Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8240 — The deploy pulls without asking GitHub for anything.

  The registry is ours, so the server pulls with a credential we issue rather
  than one Sam's GitHub account grants. A deploy that reached GHCR would put a
  GitHub token on every app server and make image pulls fail whenever Sam
  rotated it or left the org — a coupling between "can I deploy" and "is my
  GitHub still connected" that nothing about deploying justifies.

  Asserted on where the image is addressed, because that is what decides who
  gets asked at pull time.

  Surface: `CodeMySpecWeb.ProvisioningLive`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers
  setup :real_working_directory

  spex "The deploy pulls without asking GitHub for anything" do
    scenario "the image is addressed at our registry, not at GitHub" do
      given_ "Sam has a project ready to deploy", context do
        {:ok, built_deploy_run(context)}
      end

      when_ "he deploys", context do
        view = mount_provisioning(context)
        view |> element("[data-test='start-setup']") |> render_click()

        {:ok, Map.put(context, :html, await_provisioning(view))}
      end

      then_ "the image is pulled from the registry", context do
        image =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='published-image']")

        assert image != [], "the deploy recorded no image"

        assert [registry] = Floki.attribute(image, "data-registry")

        refute registry =~ "ghcr.io",
               "the deploy pulls from GitHub's registry, so every app server needs a " <>
                 "GitHub credential to start"

        refute registry =~ "github", "the image is addressed at GitHub"

        # And it is a host, not a bare name — a reference with no registry in
        # it resolves to Docker Hub, which is GitHub's problem wearing a
        # different hat.
        assert registry =~ ".", "the image has no registry host, so a pull would go to Docker Hub"

        {:ok, context}
      end
    end
  end
end
