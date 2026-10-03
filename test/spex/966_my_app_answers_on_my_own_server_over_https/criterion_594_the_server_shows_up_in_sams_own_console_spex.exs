defmodule CodeMySpecSpex.Story966.Criterion8003Spex do
  @moduledoc """
  Story 966 — My app answers on my own server over HTTPS
  Criterion 8003 — The server shows up in Sam's own console.

  The server is provisioned into Sam's own Hetzner account and he is the
  one billed for it. Nothing is held on the platform's side — he can stop
  paying CodeMySpec tomorrow and keep the box.

  Retargeted onto the console (provisioning-console-step6, unmerged): the
  server step lives on the `servers` resource group now — see criterion
  613's moduledoc. `paste_provider_credentials/1` needs the credentials-form
  (or its trigger) on the mounted view, which only the dedicated
  `/console/credentials` page carries, so it runs against a separately
  mounted credentials view.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # And a modelled shell. Without one the step shells out for real — `ssh` to
  # a TEST-NET address the fake handed back — and the click blocks behind a
  # subprocess that will never answer, which arrives as the whole test timing
  # out three minutes later with a stack in `Phoenix.LiveViewTest.call/2`.
  setup :fake_working_directory
  # After fake_working_directory: it registers the memory environment with
  # `Fakes.Shell` wired to `:memory_shell`, and `confirm_new_servers`
  # bootstraps the account server's registry/database containers through
  # that same modelled shell.
  setup :confirm_new_servers

  spex "The server shows up in Sam's own console", criterion: 594 do
    scenario "the provisioned server is recorded under Sam's own account" do
      given_ "Sam is on the setup status page with credentials entered", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers")

        # A real Hetzner server is created; register its teardown before it is
        # made so a recording that fails partway still leaves no box running.
        tear_down_after(context.scope, [:server])

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the server step has run", context do
        {:ok, credentials_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/credentials")

        paste_provider_credentials(credentials_view)

        run_console_step(context.view, :server)

        {:ok, Map.put(context, :html, render(context.view))}
      end

      then_ "the server is recorded under his own account", context do
        server =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='server']")

        # Anchor: a server resource was recorded at all.
        assert server != [], "expected the run to record the provisioned server"

        owner = server |> Floki.attribute("data-owner") |> List.first()

        assert owner == "user",
               "expected the server to be owned by Sam, got #{inspect(owner)}"

        location = server |> Floki.attribute("data-location") |> List.first()

        assert is_binary(location) and location != "",
               "expected the record to name where the server lives so Sam can find it in his console"

        {:ok, context}
      end

      then_ "nothing about it is held on the platform's side", context do
        refute context.html =~ ~r/data-kind="server"[^>]*data-owner="platform"/,
               "expected no part of the server to be held by the platform"

        {:ok, context}
      end
    end
  end
end
