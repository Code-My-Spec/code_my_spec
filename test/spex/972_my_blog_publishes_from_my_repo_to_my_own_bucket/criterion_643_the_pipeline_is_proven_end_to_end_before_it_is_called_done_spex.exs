defmodule CodeMySpecSpex.Story972.Criterion8039Spex do
  @moduledoc """
  Story 972 — My blog publishes from my repo to my own bucket
  Criterion 8039 — The pipeline is proven end to end before it is called done.

  The publishing step does not report done on the strength of having written
  configuration. It publishes a real post, confirms it rendered on the
  deployed site, and only then marks itself finished — the same
  prove-it-before-claiming-it gate as the backup restore in 968 and the
  inbound delivery in 974.

  Retargeted onto the console (provisioning-console-step6, unmerged): each
  resource group is its own route now, so the `given_` below mounts one page
  per group (credentials, repository, servers, secrets, dns_domain, deploys,
  publishing) instead of the one page `mount_provisioning` used to hand every
  step — see criterion 748's moduledoc for the general shape of the move.
  `paste_provider_credentials/1` and `open_secrets_dialog/1` both guard on
  the form already being present (058d20ed/7ba5d249), so they work unchanged
  against `/console/credentials` and `/console/secrets`, which render their
  forms directly with no dialog to open.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Provisioning.ContentPublishing`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  # Two blocks, two cassettes. Both used to be recorded under one name, and a
  # cassette is loaded and consulted when it is entered — so the second block
  # replayed the first block's reads. The deploy step was answered with the
  # server list recorded before any server existed and reported that the box
  # the previous step had just created was missing.

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  # A real application on disk, because the deploy step runs `bin/deploy` from
  # the project's cwd and the stub directory has no such script.
  setup :fake_working_directory
  setup :fake_providers
  # A publish refuses outright without content_bucket, client_api_url and
  # deploy_key — "Publishing is not configured" — so the step never reaches
  # storage and the criterion reads that as nothing having been written.
  setup :publishing_configured

  spex "The pipeline is proven end to end before it is called done", criterion: 643 do
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
          CodeMySpec.ExecutionContexts.write_file(
            context.execution_context,
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

        # Every pasted credential, not just the storage pair. This `given_`
        # runs the server step, which needs the Hetzner API token —
        # `paste_storage_credentials/1` omits it, so the sequence halted at
        # `server` and the steps after it never ran.
        {:ok, credentials_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/credentials")

        paste_provider_credentials(credentials_view)

        {:ok, repository_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/repository")

        run_console_step(repository_view, :repository)

        {:ok, servers_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers")

        run_console_step(servers_view, :server)
        run_console_step(servers_view, :secrets)

        # The app refuses to boot without these, and `check_secrets/2` is the
        # first thing in the deploy step's `with` — so without them the deploy
        # never reaches its script and the site never exists. Filled in after
        # the `secrets` step above, which is what mints the age key they are
        # encrypted to.
        {:ok, secrets_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/secrets")

        for {key, value} <- [
              {"SECRET_KEY_BASE", String.duplicate("s", 64)},
              {"DATABASE_URL", "ecto://postgres:postgres@127.0.0.1/drill_uat"}
            ] do
          secrets_view
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

        # The domain the drill application is actually built for. Its
        # `config/deploy.uat.yml` names `uat.drill.astralbi.com`, and
        # `config_targets_this_project/2` refuses to deploy when the config's
        # proxy host belongs to a different project — correctly, since that is
        # how one project's app lands on another's host. Giving this criterion
        # its own subdomain made the guard refuse and the deploy step do
        # nothing at all, silently, between dns and storage.
        own_domain(context.project, "drill.astralbi.com")

        {:ok, dns_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/dns_domain")

        run_console_step(dns_view, :domain)
        run_console_step(dns_view, :dns)

        {:ok, deploys_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys")

        deploys_view
        |> form(
          "[data-test='deploy-row'][data-environment='uat'] [data-test='deploy-environment-form']",
          %{"environment" => "uat"}
        )
        |> render_submit()

        # No `:storage`. That step provisions object storage on Hetzner, which
        # is a different story's claim — this one is about the content pipeline
        # proving a render before reporting done, and it publishes to the
        # fleet's MinIO bucket that `publishing_configured` configures. Running
        # both left the criterion with two halves disagreeing about whose
        # storage it was using: the deploy made Hetzner buckets and the content
        # step read one back, against a cassette recorded for neither.
        {:ok, publishing_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/publishing")

        {:ok, Map.put(context, :view, publishing_view)}
      end

      when_ "it verifies itself", context do
        # Synchronous in test (`config :code_my_spec, :provisioning_run_async,
        # false`), so `run_console_step/2` returns only once the step has
        # settled — unlike the old page, there is nothing left to await here.
        run_console_step(context.view, :content)
        html = render(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it confirmed a real post rendered on the deployed site", context do
        parsed = Floki.parse_document!(context.html)

        proof = parsed |> Floki.find("[data-test='content-render-proof']")

        # Report what the page says about the failure, not only that the proof
        # is missing. A publish that uploaded and could not be served renders
        # `content-publish-error` right beside the absent proof, carrying the
        # reason — so the page knew "500, deploy key not configured" while this
        # assertion said "no render proof", and the two read as completely
        # different problems.
        #
        # That gap cost a second 440s live recording. The absence of a proof is
        # the same page state whether the step never ran, ran and refused, or
        # was never built; the annotation beside it is what tells them apart,
        # and it was there both times.
        publish_error =
          parsed
          |> Floki.find("[data-test='content-publish-error']")
          |> Floki.text()
          |> String.trim()

        # Anchor: a proof exists rather than only a configuration summary.
        # `inspect/1` rather than a branch on whether there is an error: an
        # empty string prints as `""`, which reads as "the page reported no
        # publish error" without a conditional deciding what the message says.
        assert proof != [],
               "expected the content step to record a render proof; " <>
                 "publish error on the page: #{inspect(publish_error)}"

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
          |> Floki.find("[data-test='resource-step'][data-step='content']")
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
