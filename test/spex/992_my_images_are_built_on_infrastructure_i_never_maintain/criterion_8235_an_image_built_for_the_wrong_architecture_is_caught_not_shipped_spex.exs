defmodule CodeMySpecSpex.Story992.Criterion8235Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8235 — An image built for the wrong architecture is caught, not
  shipped.

  8234's failure path, and the reason the builder reads the architecture off
  the image it produced rather than echoing the one it was asked for: a check
  against your own request always passes.

  The failure this prevents is a deploy that succeeds. The image publishes, the
  swap runs, and the container dies at start — by which point the deploy has
  already reported itself healthy. So the assertion is a negative: nothing was
  published, and the step did not call itself done.

  Surface: `CodeMySpecWeb.ProvisioningLive`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers
  setup :real_working_directory

  spex "An image built for the wrong architecture is caught, not shipped" do
    scenario "a build that produced the other architecture publishes nothing" do
      given_ "Sam's environment runs on arm but the build produces x86", context do
        {:ok, built_deploy_run(context, architecture: :arm, builds: :x86)}
      end

      when_ "he deploys", context do
        view = mount_provisioning(context)
        view |> element("[data-test='start-setup']") |> render_click()

        {:ok, Map.put(context, :html, await_provisioning(view))}
      end

      then_ "no image was published", context do
        document = Floki.parse_document!(context.html)

        assert Floki.find(document, "[data-test='published-image']") == [],
               "a mismatched image was published — it would deploy cleanly and die at " <>
                 "container start"

        {:ok, Map.put(context, :document, document)}
      end

      then_ "and the deploy did not report itself done", context do
        refute context.html =~ ~r/data-step="deploy"[^>]*data-state="done"/,
               "the deploy called itself done on a build it should have refused"

        {:ok, context}
      end
    end
  end
end
