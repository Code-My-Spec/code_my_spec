defmodule CodeMySpecSpex.Story963.Criterion7964Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7964 — A resource deleted behind setup's back is rebuilt, not skipped.

  A step that succeeded once is not trusted forever. If Sam deletes the
  server in the Hetzner console, the next run finds it missing and runs
  the server step again rather than skipping on the strength of the old
  result. This is what makes the status page's state trustworthy instead
  of merely remembered.

  Two cassettes: the first provisions the server, the second answers
  "that server does not exist" when setup re-checks.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # The registry runs on the box over SSH, and the box in a cassette is an
  # address that was released weeks ago — so this once stepped out to a
  # stranger's machine and failed with `ssh: connect to host … Operation timed
  # out`. It then ran against the local fleet's app box, which fixed the
  # address and made the criterion green on exactly one machine: `fleet_box`
  # raises "No fleet key" anywhere `docker/fleet/fleet.sh up` has not been run.
  #
  # The modelled shell answers the SSH instead. What this criterion is about —
  # that a step re-checks the provider rather than trusting its own record — is
  # a claim about our logic, and needs no box at all.
  setup :fake_working_directory
  # After fake_working_directory: it registers the memory environment with
  # `Fakes.Shell` wired to `:memory_shell`, and `confirm_new_servers`
  # bootstraps the account server's registry/database containers through
  # that same modelled shell.
  setup :confirm_new_servers

  spex "A resource deleted behind setup's back is rebuilt, not skipped" do
    scenario "the server step runs again when the server is gone" do
      given_ "the server step previously succeeded", context do
        # Before the page mounts. The LiveView reads the project once, at mount;
        # claiming the repository afterwards updates the row but not the socket,
        # so the step still saw a repository belonging to nobody and paused.
        own_repository(context.project)

        view = mount_provisioning(context)

        # Everything the server step needs before it can reach Hetzner, and
        # a teardown registered before anything is made — a recording that
        # fails partway must still not leave a box running.
        # `:storage` as well as `:server`. The server step also provisions the
        # registry's buckets, and only the box was being torn down — so every
        # run left `spex-story963-criterion7964-registry-{prod,uat}` behind,
        # and the residue guard then refused to start the *next* run. A
        # criterion that cannot be recorded twice in a row is one whose
        # teardown is short.
        tear_down_after(context.scope, [:server, :storage])

        # The repository too, so the next recording starts from one that does not
        # exist — a repository carrying an earlier run's commits rejects a fresh
        # push as non-fast-forward (which is 8184's subject, not this one's).
        tear_down_repository(context.project)

        # Saving a credential proves it with a real call now, so this is a
        # provider interaction and belongs inside the cassette.
        paste_provider_credentials(view)

        view
        |> element("[data-test='setup-step'][data-step='server'] [data-test='run-step']")
        |> render_click()

        html = render(view)

        assert html =~ ~r/data-step="server"[^>]*data-state="done"/,
               "expected the server step to be done before the resource is deleted. " <>
                 step_detail(html, "server")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam has deleted that server and setup runs again", context do
        # The cassette answers the existence check with "not found", which
        # is how setup learns the resource is gone.
        context.view |> element("[data-test='start-setup']") |> render_click()

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "setup runs the server step again rather than skipping it", context do
        assert context.html =~ ~r/data-step="server"[^>]*data-state="(running|done)"/,
               "expected the server step to be re-run once its resource was found missing"

        refute context.html =~ ~r/data-step="server"[^>]*data-state="skipped"/,
               "expected setup not to skip the step on the strength of the old result"

        {:ok, context}
      end
    end
  end
end
