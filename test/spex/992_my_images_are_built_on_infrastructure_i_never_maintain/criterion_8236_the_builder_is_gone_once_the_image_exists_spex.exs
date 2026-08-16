defmodule CodeMySpecSpex.Story992.Criterion8236Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8236 — The builder is gone once the image exists.

  "Infrastructure I never maintain" is not only about who configures the box.
  A builder that keeps running is a box Sam pays for and nobody watches, and
  its failure mode is silence: the image still arrives, the deploy still
  succeeds, and the only symptom is an invoice.

  So the disposition is recorded rather than assumed. The builder is destroyed
  on every path out of the build — including a raise — but a criterion that
  asserted that from a constant would keep reading true after it stopped being
  true, which is the failure it exists to catch.

  Surface: `CodeMySpecWeb.ProvisioningLive`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # Fakes rather than cassettes: these criteria drive the deploy step, whose
  # Hetzner calls fall outside every cassette — `cannot find mock/stub`,
  # reported as whatever the criterion was asserting.
  setup :fake_providers
  setup :real_working_directory

  spex "The builder is gone once the image exists" do
    scenario "a successful build leaves no builder behind" do
      given_ "Sam has a project ready to deploy", context do
        {:ok, built_deploy_run(context)}
      end

      when_ "he deploys and the image is built", context do
        view = mount_provisioning(context)
        view |> element("[data-test='start-setup']") |> render_click()

        {:ok, Map.put(context, :html, await_provisioning(view))}
      end

      then_ "the image exists", context do
        document = Floki.parse_document!(context.html)

        assert Floki.find(document, "[data-test='published-image']") != [],
               "no image was built, so this criterion has nothing to say about the builder"

        {:ok, Map.put(context, :document, document)}
      end

      then_ "and the builder that made it is gone", context do
        builder = Floki.find(context.document, "[data-test='builder']")

        assert builder != [], "the deploy did not record which builder made the image"

        assert Floki.attribute(builder, "data-destroyed") == ["true"],
               "the builder outlived the build — a box Sam pays for and nobody watches"

        {:ok, context}
      end
    end
  end
end
