defmodule CodeMySpecSpex.Story972.Criterion8039Spex do
  @moduledoc """
  Story 972 — My blog publishes from my repo to my own bucket
  Criterion 8039 — The pipeline is proven end to end before it is called done.

  The publishing step does not report done on the strength of having written
  configuration. It publishes a real post, confirms it rendered on the
  deployed site, and only then marks itself finished — the same
  prove-it-before-claiming-it gate as the backup restore in 968 and the
  inbound delivery in 974.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.ContentPublishing`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "content_step_proves_render_before_done"

  # Two blocks, two cassettes. Both used to be recorded under one name, and a
  # cassette is loaded and consulted when it is entered — so the second block
  # replayed the first block's reads. The deploy step was answered with the
  # server list recorded before any server existed and reported that the box
  # the previous step had just created was missing.
  @given_cassette "972_8039_site_deployed"

  @deploy_cassette "972_8039_site_deployed_deploy"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  # A real application on disk, because the deploy step runs `bin/deploy` from
  # the project's cwd and the stub directory has no such script.
  setup :drill_working_directory
  setup :connect_providers
  # A publish refuses outright without content_bucket, client_api_url and
  # deploy_key — "Publishing is not configured" — so the step never reaches
  # storage and the criterion reads that as nothing having been written.
  setup :publishing_to_the_fleet

  spex "The pipeline is proven end to end before it is called done" do
    scenario "the step confirms a rendered post before reporting done" do
      # Renamed, and made true. The old title said the publishing step had
      # already configured everything, but the `when_` is that step running —
      # so the precondition described the thing under test. What it actually
      # needs is somewhere to publish *to*: a bucket and a deployed site, or
      # the render proof has nothing to fetch and the step fails for a reason
      # that has nothing to do with proving a render.
      given_ "Sam's site is deployed and his storage is ready", context do
        # A post to publish. Without one the step uploads an empty content set
        # and then waits for `/blog/hello` to appear, which it never can — the
        # criterion was asserting that a pipeline proves a render while giving
        # it nothing to render. `type: blog` is load-bearing: without it the
        # row has no content type and parses as an error rather than a post.
        :ok =
          CodeMySpec.Environments.write_file(
            context.environment,
            "content/posts/hello.md",
            "---\ntitle: Hello\ntype: blog\n---\n\nProven end to end.\n"
          )

        # Registered before the run, so it happens even when the sequence
        # halts partway. This spex creates a real server and real buckets and
        # was tearing down neither: the first drill left two servers running
        # and `mix cms.provisioning_leaks` reports servers but never deletes
        # them, so they had to be removed by hand.
        tear_down_after(context.scope, [:server, :storage, :dns])

        # The repository too, which product teardown deliberately never
        # touches — deleting a customer's repo is not setup's business. But
        # this spex makes a real one in the test org every run, and the one it
        # left behind is why the second drill paused on a name collision
        # instead of provisioning.
        tear_down_repository(context.project)

        # Ask for an image to be built. Without `:image` or `:build`,
        # `image_for/3` answers `:not_built` and the deploy step does nothing
        # at all — no shell command, no error on the page, just an absence
        # between dns and storage. There is no site afterwards, so the render
        # proof this criterion is about has nothing to fetch.
        previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

        Application.put_env(
          :code_my_spec,
          :provisioning_step_opts,
          Keyword.put(previous, :build, true)
        )

        ExUnit.Callbacks.on_exit(fn ->
          Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
        end)

        # Mounted before the domain is set, and that ordering is load-bearing.
        # `ProvisioningLive.load/2` lists Resend's domains at mount whenever the
        # project has one, and the mount sits outside every cassette by design
        # — the idiom across this epic is mount, then `run_steps` with a
        # cassette. So a domain set first put a `GET /domains` into the one
        # place no recording can cover, and replay failed in `mount/3` with
        # "cannot find mock/stub", which reads as process scoping rather than
        # as a call nothing was recording.
        view = mount_provisioning(context)

        # The domain the drill application is actually built for. Its
        # `config/deploy.uat.yml` names `uat.drill.astralbi.com`, and
        # `config_targets_this_project/2` refuses to deploy when the config's
        # proxy host belongs to a different project — correctly, since that is
        # how one project's app lands on another's host. Giving this criterion
        # its own subdomain made the guard refuse and the deploy step do
        # nothing at all, silently, between dns and storage.
        #
        # The steps this `given_` runs — repository, server, secrets — need no
        # domain, and the ones that do run later against the database rather
        # than the mount's assigns.
        own_domain(context.project, "drill.astralbi.com")

        # Every pasted credential, not just the storage pair. This `given_`
        # runs the server step, which needs the Hetzner API token —
        # `paste_storage_credentials/1` omits it, so the sequence halted at
        # `server` and the steps after it never ran. The recording that
        # produced was four interactions long and stopped at the repository.
        paste_provider_credentials(view)
        run_steps(view, [:repository, :server, :secrets], @given_cassette)

        # The app refuses to boot without these, and `check_secrets/2` is the
        # first thing in the deploy step's `with` — so without them the deploy
        # never reaches its script and the site never exists. Set after the
        # `secrets` step, which is what mints the age key they are encrypted
        # to.
        for {key, value} <- [
              {"SECRET_KEY_BASE", String.duplicate("s", 64)},
              {"DATABASE_URL", "ecto://postgres:postgres@127.0.0.1/drill_uat"}
            ] do
          view
          |> form("[data-test='secret-form']",
            secret: %{environment: "uat", key: key, value: value}
          )
          |> render_submit()
        end

        # What setup just wrote has to be in a commit before it can be
        # deployed: the image is versioned by commit SHA and `bin/deploy`
        # refuses a dirty tree. This is what a customer does after their first
        # setup run.
        commit_generated_files(context.project.local_path)

        # No `:storage`. That step provisions object storage on Hetzner, which
        # is a different story's claim — this one is about the content pipeline
        # proving a render before reporting done, and it publishes to the
        # fleet's MinIO bucket that `publishing_to_the_fleet` configures. Running
        # both left the criterion with two halves disagreeing about whose
        # storage it was using: the deploy made Hetzner buckets and the content
        # step read one back, against a cassette recorded for neither.
        #
        # Method and URI rather than the default: the S3 puts carry bodies the
        # recorder does not capture, so a body-inclusive match cannot find them
        # again.
        run_steps(view, [:domain, :dns, :deploy], @deploy_cassette,
          match_requests_on: [:method, :uri]
        )

        trace_steps(view, [:repository, :server, :secrets, :domain, :dns, :deploy])

        {:ok, Map.put(context, :view, view)}
      end

      when_ "it verifies itself", context do
        html =
          with_provider_cassette(@cassette, [match_requests_on: [:method, :uri]], fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='content'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it confirmed a real post rendered on the deployed site", context do
        parsed = Floki.parse_document!(context.html)

        proof = parsed |> Floki.find("[data-test='content-render-proof']")

        # Anchor: a proof exists rather than only a configuration summary.
        assert proof != [], "expected the content step to record a render proof"

        state = proof |> Floki.attribute("data-state") |> List.first()

        assert state == "rendered",
               "expected the proof to be an actual rendered post, got #{inspect(state)}"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "only then is the step marked done", context do
        assert context.html =~ ~r/data-step="content"[^>]*data-state="done"/,
               "expected the content step to be done once the render was proven"

        proven_at =
          context.parsed
          |> Floki.find("[data-test='content-render-proof']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        done_at =
          context.parsed
          |> Floki.find("[data-test='setup-step'][data-step='content']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        assert is_binary(proven_at) and is_binary(done_at),
               "expected both the proof and the step completion to be timestamped"

        assert proven_at <= done_at,
               "expected the render proof to precede the step being called done: proven_at=#{proven_at} done_at=#{done_at}"

        {:ok, context}
      end
    end
  end
end
