defmodule CodeMySpecSpex.Story992.Criterion8232Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8232 — Creating a project builds nothing.

  Building at project creation was the original shape and it was wrong twice
  over: every new project waited on a build before it was usable, and it tied
  "my history reached the remote" to "CI finished", which are two different
  claims. A build is something Sam asks for by deploying.

  The claim is a negative, so it is asserted against the page rather than
  against a spy: after creating a project there is no image on it. A build that
  had happened would have recorded one, because that is the only way a built
  image ever gets there.

  Surface: `CodeMySpecWeb.ProvisioningLive`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "Creating a project builds nothing" do
    scenario "a newly created project has no image and no builder" do
      given_ "Sam has just created a project", context do
        # Created here rather than in a `setup` callback, because creating it
        # *is* the precondition and a block that states one without doing
        # anything cannot be told apart from a block that forgot to.
        #
        # And nothing else. No run, scripted or otherwise — anything more
        # would be the deploy this criterion says must not have happened yet.
        context = setup_active_project(context)

        {:ok, devops_on(context)}
      end

      when_ "he opens setup without deploying", context do
        view = mount_provisioning(context)

        {:ok, Map.put(context, :html, render(view))}
      end

      then_ "nothing has been built", context do
        document = Floki.parse_document!(context.html)

        assert Floki.find(document, "[data-test='published-image']") == [],
               "a project that was only created has an image, so something built one"

        # And the deploy step — the only thing that builds — has not run.
        refute context.html =~ ~r/data-step="deploy"[^>]*data-state="done"/,
               "the deploy finished on a project nobody deployed"

        {:ok, context}
      end
    end
  end
end
