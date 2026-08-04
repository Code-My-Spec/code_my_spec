defmodule CodeMySpecSpex.Story992.Criterion8233Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8233 — Deploying builds the image on demand.

  The other half of 8232. Creating a project builds nothing; deploying is the
  moment a build happens, because it is the first moment anyone knows what to
  build.

  The build itself is injected. A container build is minutes of output with
  non-deterministic layer digests, invalidated by any Dockerfile edit, and it
  would prove Docker works rather than anything of ours. What is ours — that a
  deploy asks for a build at all, and records what came back — is what this
  asserts, through the page.

  Surface: `CodeMySpecWeb.ProvisioningLive`, driving
  `CodeMySpec.Provisioning.Builder` through the deploy step.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  # Setup refuses to start while a credential is missing (criterion 7985), so
  # without this the run never begins and this criterion reports "nothing was
  # built" — which is true, and nothing to do with what it is asking.
  setup :connect_providers
  setup :real_working_directory

  spex "Deploying builds the image on demand" do
    scenario "the deploy step builds and records the image it produced" do
      given_ "Sam has a project that has never been built", context do
        {:ok, built_deploy_run(context)}
      end

      when_ "he deploys", context do
        view = mount_provisioning(context)

        html =
          view
          |> element("[data-test='start-setup']")
          |> render_click()
          |> then(fn _ -> await_provisioning(view) end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the image the deploy runs was built by this deploy", context do
        image =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='published-image']")
          |> List.first()

        assert image, "the deploy recorded no image at all"

        assert Floki.attribute([image], "data-built") == ["true"],
               "the deploy ran an image it did not build — 8233 is that deploying is " <>
                 "what causes a build"

        # Tagged by the commit, so "which image is this" and "which code is
        # this" are not two questions.
        assert [reference] = Floki.attribute([image], "data-image")
        assert reference =~ ~r/:[0-9a-f]{12}$/, "expected the image tagged by its commit"

        {:ok, context}
      end
    end
  end
end
