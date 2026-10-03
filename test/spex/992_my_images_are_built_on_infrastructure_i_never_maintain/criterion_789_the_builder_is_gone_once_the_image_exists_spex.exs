defmodule CodeMySpecSpex.Story992.Criterion8236Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8236 — The builder is gone once the image exists.

  "Infrastructure I never maintain" is not only about who configures the box.
  A builder that keeps running is a box Sam pays for and nobody watches, and
  its failure mode is silence: the image still arrives, the deploy still
  succeeds, and the only symptom is an invoice.

  Story 877 changed what "gone" means: the box is now the one shared burst
  box an environment has, found rather than created per build, so it cannot
  be destroyed unconditionally without destroying something another build or
  embedding runner might still be using. What stayed the same is the
  discipline this criterion is actually about — the box is asked whether it
  should go on every single path out of the build, not just when someone
  remembers to check, and the answer is recorded rather than assumed. This
  scenario forces the one case `builder_destroyed` can actually be `true`:
  the box is due for its end-of-billing-hour check and nothing else is using
  it.
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

  spex "The builder is gone once the image exists", criterion: 789 do
    scenario "a successful build leaves an idle, due shared box released" do
      given_ "Sam's build will land on a shared box that is due for its end-of-hour check and idle",
             context do
        {:ok, built_deploy_run(context, box_release: :idle)}
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

      then_ "and the box is released, because nothing else was using it", context do
        builder = Floki.find(context.document, "[data-test='builder']")

        assert builder != [], "the deploy did not record which box it built on"

        assert Floki.attribute(builder, "data-destroyed") == ["true"],
               "the box was due for a check and idle, and outlived it anyway — a box Sam " <>
                 "pays for and nobody watches"

        {:ok, context}
      end
    end
  end
end
