defmodule CodeMySpecSpex.Story992.Criterion8234Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8234 — The builder produces an image the server can run.

  The builder is a different machine from the one the app runs on, so "it
  built" and "it can run there" are two claims. An image built for the other
  architecture starts and immediately dies, and the deploy looks healthy right
  up until the swap.

  Asserted for x86 rather than the default, because the interesting failure is
  a build that quietly used the default while the box was something else — the
  exact shape of the bug where the server step falls back to the other
  architecture when a region is sold out. A criterion pinned to `:arm` on both
  sides would pass no matter which one the build actually used.

  Surface: `CodeMySpecWeb.ProvisioningLive`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers
  setup :real_working_directory

  spex "The builder produces an image the server can run" do
    scenario "the image is built for the architecture the environment's box runs" do
      given_ "Sam's environment runs on x86", context do
        {:ok, built_deploy_run(context, architecture: :x86)}
      end

      when_ "he deploys", context do
        view = mount_provisioning(context)
        view |> element("[data-test='start-setup']") |> render_click()

        {:ok, Map.put(context, :html, await_provisioning(view))}
      end

      then_ "the image records the architecture the box runs", context do
        image =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='published-image']")

        assert image != [], "the deploy recorded no image"

        assert Floki.attribute(image, "data-architecture") == ["x86"],
               "the image was not built for the architecture the environment runs — " <>
                 "an image built for the other one starts and dies"

        {:ok, context}
      end
    end
  end
end
