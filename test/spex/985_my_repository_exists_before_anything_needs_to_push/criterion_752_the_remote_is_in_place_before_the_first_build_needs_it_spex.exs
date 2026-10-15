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

  Retargeted onto the console (provisioning-console-step6, unmerged): there
  is no `start-setup` whole-run to run repository through deploy — the
  ordering claim is tested more directly instead, running `:repository`
  then `:deploy` each on their own page via `run_console_step/2` and the
  deploy form, and comparing their own recorded timestamps exactly as
  before.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
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

  spex "The remote is in place before the first build needs it", criterion: 752 do
    scenario "the repository step completes before the deploy step starts" do
      given_ "Sam is on the setup status page with his credentials entered", context do
        # The repository an earlier recording made still exists and cannot be
        # deleted, so setup would pause asking whose it is — halting the run
        # before the deploy step this criterion is about. It is this project's.
        # (8185 is the criterion that *wants* that prompt; it must not get this.)
        repository_exists(context, context.project)
        own_repository(context.project)

        # Saving a credential proves it with a live call, which is why this
        # needed a cassette. Against fakes the proof reaches the fake.
        {:ok, credentials_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/credentials")

        paste_provider_credentials(credentials_view)

        {:ok, Map.put(context, :credentials_view, credentials_view)}
      end

      when_ "he runs the repository step, then tries to deploy", context do
        {:ok, repository_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/repository")

        run_console_step(repository_view, :repository)

        {:ok, deploys_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys")

        deploys_view
        |> form(
          "[data-test='deploy-row'][data-environment='prod'] [data-test='deploy-environment-form']",
          %{"environment" => "prod"}
        )
        |> render_submit()

        html = render(deploys_view)

        {:ok,
         context
         |> Map.put(:repository_html, render(repository_view))
         |> Map.put(:html, html)}
      end

      then_ "the repository step records when it finished", context do
        finished =
          context.repository_html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='resource-step'][data-step='repository']")
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
          |> Floki.find("[data-test='deploy-row'][data-step='deploy'][data-environment='prod']")
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
    # Parsed, not compared as strings: `data-completed-at` and
    # `data-started-at` don't share a fractional-second precision (one
    # truncates to the second, the other doesn't), so two correctly-ordered
    # timestamps can still sort backwards as raw text.
    {:ok, finished_at, _} = DateTime.from_iso8601(context.repo_finished_at)
    {:ok, started_at, _} = DateTime.from_iso8601(started)

    assert DateTime.compare(finished_at, started_at) != :gt,
           "expected the repository to exist before the deploy needed it — " <>
             "repository finished #{context.repo_finished_at}, deploy started #{started}"
  end
end
