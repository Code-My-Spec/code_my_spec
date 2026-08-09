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

  @given_cassette "972_8039_site_deployed"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  # A real application on disk, because the deploy step runs `bin/deploy` from
  # the project's cwd and the stub directory has no such script.
  setup :drill_working_directory
  setup :connect_providers

  spex "The pipeline is proven end to end before it is called done" do
    scenario "the step confirms a rendered post before reporting done" do
      # Renamed, and made true. The old title said the publishing step had
      # already configured everything, but the `when_` is that step running —
      # so the precondition described the thing under test. What it actually
      # needs is somewhere to publish *to*: a bucket and a deployed site, or
      # the render proof has nothing to fetch and the step fails for a reason
      # that has nothing to do with proving a render.
      given_ "Sam's site is deployed and his storage is ready", context do
        # A domain, before anything runs. The `domain` and `dns` steps have
        # nothing to register without one, and the render proof has nowhere to
        # fetch from — the first drill made a server and two buckets and then
        # stopped here, having never touched Cloudflare.
        # The domain the drill application is actually built for. Its
        # `config/deploy.uat.yml` names `uat.drill.astralbi.com`, and
        # `config_targets_this_project/2` refuses to deploy when the config's
        # proxy host belongs to a different project — correctly, since that is
        # how one project's app lands on another's host. Giving this criterion
        # its own subdomain made the guard refuse and the deploy step do
        # nothing at all, silently, between dns and storage.
        own_domain(context.project, "drill.astralbi.com")

        # Registered before the run, so it happens even when the sequence
        # halts partway. This spex creates a real server and real buckets and
        # was tearing down neither: the first drill left two servers running
        # and `mix cms.provisioning_leaks` reports servers but never deletes
        # them, so they had to be removed by hand.
        tear_down_after(context.scope, [:server, :storage, :dns])

        # Ask for an image to be built. Without `:image` or `:build`,
        # `image_for/3` answers `:not_built` and the deploy step does nothing
        # at all — no shell command, no error on the page, just an absence
        # between dns and storage. There is no site afterwards, so the render
        # proof this criterion is about has nothing to fetch.
        previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])
        Application.put_env(:code_my_spec, :provisioning_step_opts, Keyword.put(previous, :build, true))

        ExUnit.Callbacks.on_exit(fn ->
          Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
        end)

        view = mount_provisioning(context)

        # Every pasted credential, not just the storage pair. This `given_`
        # runs the server step, which needs the Hetzner API token —
        # `paste_storage_credentials/1` omits it, so the sequence halted at
        # `server` and the steps after it never ran. The recording that
        # produced was four interactions long and stopped at the repository.
        paste_provider_credentials(view)
        run_steps(view, [:repository, :server, :secrets, :domain, :dns, :deploy, :storage], @given_cassette)

        if System.get_env("SPEX_DRILL_TRACE") do
          doc = view |> Phoenix.LiveViewTest.render() |> Floki.parse_document!()

          for key <- ~w(repository server secrets domain dns deploy storage) do
            step = Floki.find(doc, "[data-test='setup-step'][data-step='#{key}']")
            state = step |> Floki.attribute("data-state") |> List.first()
            # `boot-failure` as well as `escalation`: the deploy step's
            # provider error lives only in the former, because printing it in
            # both made the step look like two problems.
            why =
              step
              |> Floki.find("[data-test='escalation'], [data-test='boot-failure'], [data-test='paused-instructions']")
              |> Floki.text()
            IO.puts("STEP #{String.pad_trailing(key, 11)} #{state}  #{String.slice(why, 0, 160)}")
          end
        end

        {:ok, Map.put(context, :view, view)}
      end

      when_ "it verifies itself", context do
        html =
          with_provider_cassette(@cassette, fn ->
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
