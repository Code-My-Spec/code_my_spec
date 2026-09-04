defmodule CodeMySpecSpex.Story841.Criterion1969Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1969 — The repo can rebuild the infrastructure from scratch.

  Nothing that matters lives only in a console. If a box is lost, what is in
  the repo is enough to make it again — otherwise the infrastructure is a set
  of manual steps someone did once and cannot repeat.

  Surface: `run_devops_setup` MCP tool against a project whose resources are
  gone, then `devops_status` to ask whether they are back. Rebuilding is the
  claim, so the check is that it actually rebuilds rather than that files
  describing it exist.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Devops.Tools.{DevopsStatus, RunDevopsSetup}

  # The widget message travels over a real socket, and `connect/3` reads this.
  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # A modelled shell over the memory filesystem, so a step reading what an
  # earlier step wrote finds it.
  setup :fake_working_directory
  # After fake_working_directory: it registers the memory environment with
  # `Fakes.Shell` wired to `:memory_shell`, and `confirm_new_servers`
  # bootstraps the account server's registry/database containers through
  # that same modelled shell.
  setup :confirm_new_servers

  spex "The repo can rebuild the infrastructure from scratch" do
    scenario "the resources are gone, and setup makes them again" do
      given_ "the repo holds its deployment configuration, and nothing is provisioned",
             context do
        # Its own domain, or the domain step refuses and every step behind it
        # reports nothing — the gap 1961 had.
        own_domain(context.project, "c1969.legwork.ca")

        # And a zone covering it, so `ensure_domain` adopts rather than
        # offering to buy the name.
        zone_exists(context, "legwork.ca")

        # A checkout the deploy step accepts, after the domain because the
        # generated `config/deploy.yml` names the host it deploys to.
        deploy_ready_checkout(context)

        # A visitor who has used the widget: the widget step reports done only
        # on a message from the deployed site, and a criterion asserting the
        # rebuild *finishes* has to say where that came from.
        visitor_message_from(context, "https://c1969.legwork.ca")

        # And an address inbound can prove delivery to — 7df39199/2f8c4208
        # correctly stopped the step from guessing one, so without this it
        # pauses and storage/backups/content/callback_credential behind it
        # never run either, same reasoning as `visitor_message_from` above.
        :ok = inbound_probe_configured("sam@c1969.legwork.ca")

        # "From scratch" is the premise, so nothing is provisioned — this
        # scenario never runs setup before the `when_`. What has to be
        # established is the other half: the repo actually carries the
        # configuration a rebuild would read. If that only ever lived in a
        # console, there is nothing to rebuild from.
        # Its own hostname, not `uat.example.com`. The deploy step refuses a
        # config pointing at a host the project does not own — "point the
        # config at the right hostname, or fix the project's domain" — so a
        # premise naming somebody else's domain describes a repo that cannot
        # rebuild anything, which is the opposite of what it is here to say.
        :ok =
          CodeMySpecSpex.Fixtures.write_file(
            context.environment,
            "config/deploy.uat.yml",
            "service: story841\nimage: story841\nproxy:\n  host: uat.c1969.legwork.ca\n"
          )

        {:ok, context}
      end

      when_ "setup is run again from what the repo holds", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _run, _frame} =
          RunDevopsSetup.execute(%{project_id: to_string(context.project.id)}, frame)

        {:reply, status, _frame} = DevopsStatus.execute(%{}, frame)
        report = response_text(status)

        {:ok, Map.put(context, :report, report)}
      end

      then_ "the infrastructure is back", context do
        assert context.report =~ "Setup is complete",
               "expected a rebuild from the repo to restore the infrastructure, got: #{context.report}"

        {:ok, context}
      end

      then_ "nothing was left needing a person in a console", context do
        refute context.report =~ "Cannot say",
               "a rebuild that cannot read its own providers has not proven anything"

        {:ok, context}
      end
    end
  end
end
