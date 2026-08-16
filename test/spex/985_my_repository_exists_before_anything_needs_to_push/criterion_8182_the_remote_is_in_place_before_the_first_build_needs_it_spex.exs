defmodule CodeMySpecSpex.Story985.Criterion8182Spex do
  @moduledoc """
  Story 985 — My repository exists before anything needs to push
  Criterion 8182 — The remote is in place before the first build needs it.

  The repository step finishes before the deploy step starts. CI publishes the
  image the deploy pulls by commit SHA, so a deploy that runs before there is
  a remote has nothing to build from — and the failure surfaces several steps
  away from its cause.

  The ordering is asserted from recorded timestamps rather than from the step
  list's rendering order, because ordering is what matters and a list can be
  sorted for display.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Repository`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # A modelled shell over the memory filesystem: the repository step's proof
  # is a `git push`, which is a subprocess rather than an API call.
  setup :fake_working_directory

  spex "The remote is in place before the first build needs it" do
    scenario "the repository step completes before the deploy step starts" do
      # Credentials first. Setup refuses to start while one is missing
      # (criterion 7985), so without this the run never begins and the
      # criterion reports the repository step as never finishing — which is
      # true, and nothing to do with what it is asking.
      given_ "Sam is on the setup status page with his credentials entered", context do
        # The repository an earlier recording made still exists and cannot be
        # deleted, so setup would pause asking whose it is — halting the run
        # before the deploy step this criterion is about. It is this project's.
        # (8185 is the criterion that *wants* that prompt; it must not get this.)
        own_repository(context.project)

        # Saving a credential proves it with a live call, which is why this
        # needed a cassette. Against fakes the proof reaches the fake.
        view = mount_provisioning(context)
        paste_provider_credentials(view)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he runs setup", context do
        context.view
        |> element("[data-test='start-setup']")
        |> render_click()

        # Started, not finished: the click returns as soon as the run
        # begins, so the page is read once the run settles.
        await_provisioning(context.view)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the repository step records when it finished", context do
        finished =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='setup-step'][data-step='repository']")
          # `data-completed-at`, which is what every other step assertion in
          # this epic reads. A second attribute meaning the same thing is how
          # two names for one fact drift apart.
          |> Floki.attribute("data-completed-at")
          |> List.first()

        assert is_binary(finished) and finished != "",
               "expected the repository step to record when it finished"

        {:ok, Map.put(context, :repo_finished_at, finished)}
      end

      then_ "the deploy step started after it", context do
        started =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='setup-step'][data-step='deploy']")
          |> Floki.attribute("data-started-at")
          |> List.first()

        # The deploy may not have started at all — the run halts at the first
        # step that cannot finish, and on a project with no server yet that is
        # well before the deploy. That is the sequence working, not a gap in
        # it, so the assertion is the ordering rather than the arrival:
        # whenever the deploy did start, the repository was already there.
        #
        # Demanding a deploy timestamp would make this criterion require a
        # provisioned server to say anything about repository ordering, which
        # is a different and much more expensive claim.
        assert_ordering(started, context)

        {:ok, context}
      end
    end
  end

  # Function heads rather than a `case`: the two outcomes are different claims,
  # and the suite's own rule is that a spex names them rather than branching.
  defp assert_ordering(nil, context) do
    refute context.html =~ ~r/data-step="deploy"[^>]*data-state="done"/,
           "the deploy finished without ever recording a start"
  end

  defp assert_ordering(started, context) do
    assert context.repo_finished_at <= started,
           "expected the repository to exist before the deploy needed it — " <>
             "repository finished #{context.repo_finished_at}, deploy started #{started}"
  end
end
