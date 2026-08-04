defmodule CodeMySpecSpex.Story992.Criterion8237Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8237 — A failed build still takes its builder with it.

  8236's failure path, and the one that actually rots. A successful deploy that
  leaked a box at least has someone looking at it; a failed deploy already
  looks like a failure, so a leaked builder adds nothing visible to it. Nobody
  goes looking, and the box keeps billing.

  A build fails for ordinary reasons — a syntax error, a disk that filled — so
  this is the common case rather than the exotic one. The builder is destroyed
  on every path out of the build, and the failure carries what became of it
  rather than leaving the reader to assume.

  Surface: `CodeMySpecWeb.ProvisioningLive`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers
  setup :real_working_directory

  spex "A failed build still takes its builder with it" do
    scenario "a build that fails leaves no builder behind" do
      given_ "Sam's build is going to fail", context do
        {:ok, built_deploy_run(context, builds: :error)}
      end

      when_ "he deploys", context do
        view = mount_provisioning(context)
        view |> element("[data-test='start-setup']") |> render_click()

        {:ok, Map.put(context, :html, await_provisioning(view))}
      end

      then_ "nothing was published", context do
        document = Floki.parse_document!(context.html)

        assert Floki.find(document, "[data-test='published-image']") == [],
               "a build that failed published an image anyway"

        {:ok, Map.put(context, :document, document)}
      end

      then_ "and the builder was still destroyed", context do
        builder = Floki.find(context.document, "[data-test='builder']")

        assert builder != [],
               "the failed deploy recorded no builder, so nothing says whether the box " <>
                 "it made is still running"

        assert Floki.attribute(builder, "data-destroyed") == ["true"],
               "the build failed and left its builder running — the leak nobody goes " <>
                 "looking for, because the deploy already looked like a failure"

        {:ok, context}
      end
    end
  end
end
