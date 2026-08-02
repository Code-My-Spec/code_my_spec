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
  use ExCliVcr

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "setup_run_repository_then_deploy"

  # Mounting the page and saving credentials both reach providers for real —
  # saving a credential proves it with a live call. Outside a cassette they hit
  # the API while recording and the network while replaying, so on replay the
  # credentials never proved, setup refused to start, and the criterion
  # reported the repository step as never finishing.
  @given_cassette "985_8182_credentials"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "The remote is in place before the first build needs it" do
    scenario "the repository step completes before the deploy step starts" do
      # Credentials first. Setup refuses to start while one is missing
      # (criterion 7985), so without this the run never begins and the
      # criterion reports the repository step as never finishing — which is
      # true, and nothing to do with what it is asking.
      given_ "Sam is on the setup status page with his credentials entered", context do
        # This runs the whole sequence, which makes real servers, a firewall and
        # an ssh key. Nothing removed them: the run leaked two boxes per pass
        # and eventually exhausted the Hetzner server limit, which surfaced in
        # an unrelated story as "server limit reached".
        tear_down_after(context.scope, [:server])

        # The repository too, so the next recording starts from one that does not
        # exist — a repository carrying an earlier run's commits rejects a fresh
        # push as non-fast-forward (which is 8184's subject, not this one's).
        tear_down_repository(context.project)

        # The repository an earlier recording made still exists and cannot be
        # deleted, so setup would pause asking whose it is — halting the run
        # before the deploy step this criterion is about. It is this project's.
        # (8185 is the criterion that *wants* that prompt; it must not get this.)
        own_repository(context.project)

        view =
          with_provider_cassette(@given_cassette, fn ->
            view = mount_provisioning(context)
            paste_provider_credentials(view)
            view
          end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he runs setup", context do
        html =
          with_full_cassette @cassette do
            context.view
            |> element("[data-test='start-setup']")
            |> render_click()

            # Started, not finished: the click returns as soon as the run
            # begins, so the page is read once the run settles.
            await_provisioning(context.view)
          end

        {:ok, Map.put(context, :html, html)}
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
        case started do
          nil ->
            refute context.html =~ ~r/data-step="deploy"[^>]*data-state="done"/,
                   "the deploy finished without ever recording a start"

          started ->
            assert context.repo_finished_at <= started,
                   "expected the repository to exist before the deploy needed it — " <>
                     "repository finished #{context.repo_finished_at}, deploy started #{started}"
        end

        {:ok, context}
      end
    end
  end
end
