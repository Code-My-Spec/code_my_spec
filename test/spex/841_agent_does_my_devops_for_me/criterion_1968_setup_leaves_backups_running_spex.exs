defmodule CodeMySpecSpex.Story841.Criterion1968Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1968 — Setup leaves backups running.

  "Stays there" is half the story's promise. Setup that provisions and walks
  away leaves Sam with data nobody is copying, and he finds out at the worst
  possible moment.

  Surface: `devops_status` MCP tool. Backups are a step like any other, so the
  question "is this actually in place" gets the same answer from the same
  place, read from the providers rather than from a claim.

  ## Why there is no monitoring assertion here any more

  The criterion used to read "and monitors watching", and the sequence had a
  monitoring step to match. It needed a third-party account, an API key and a
  notification target that only a person can supply, so it paused on every run
  and setup could never report complete — the story's own promise was blocked
  on the one step nobody could automate.

  Narrowing the claim was the honest fix rather than the convenient one, so the
  assertion here is the strict form: the report must not mention monitoring
  *at all*. A status that listed it as missing would be an accurate complaint
  about work setup no longer claims to do, and a status that listed it as
  present would be a lie. Neither is allowed.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Devops.Tools.{DevopsStatus, RunDevopsSetup}

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # A modelled shell over the memory filesystem, so a step reading what an
  # earlier step wrote finds it — and, for this criterion in particular, so
  # `bin/backup` runs somewhere. Recording it needed a box that could take a
  # systemd unit, which is why this sat parked; against fakes the dump and the
  # restore answer each other and there is no box to find.
  setup :fake_working_directory

  spex "Setup leaves backups running" do
    scenario "setup has finished, and the dumps are landing" do
      given_ "a project whose setup has run to completion", context do
        # Its own domain, or the domain step refuses and every step behind it
        # reports nothing — the gap 1961 had.
        own_domain(context.project, "c1968.legwork.ca")

        # And a zone covering it, so `ensure_domain` adopts rather than
        # offering to buy the name.
        zone_exists(context, "legwork.ca")

        # A checkout the deploy step accepts, after the domain because the
        # generated `config/deploy.yml` names the host it deploys to. It also
        # carries `bin/backup`, which is the script this criterion is about.
        deploy_ready_checkout(context)

        # Run, not asserted. Backups being in place is what the criterion is
        # about, so the run that would put them there has to actually happen.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          RunDevopsSetup.execute(%{project_id: to_string(context.project.id)}, frame)

        {:ok, Map.put(context, :frame, frame)}
      end

      when_ "the agent asks what infrastructure exists", context do
        {:reply, response, _frame} =
          DevopsStatus.execute(%{}, %Frame{assigns: %{current_scope: context.scope}})

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "a dump is in the bucket", context do
        # The anchor this scenario did not have. Both assertions below are
        # refutes against the status report, and a refute passes when the
        # report is empty or an error — so a `devops_status` that failed
        # outright satisfied "backups are not among the missing" and "the
        # report says nothing about monitoring" alike.
        #
        # A dump in the bucket is the concrete fact behind "setup leaves
        # backups running", and it is what 968/8014 reads too.
        dumps =
          dumps_in_bucket(context, CodeMySpecSpex.Fixtures.bucket_name(context.project, "uat"))

        assert dumps != [],
               "expected setup to have taken a dump, found nothing under dumps/"

        {:ok, context}
      end

      then_ "backups are not among the missing", context do
        refute context.report =~ ~r/Missing.*backups/s,
               "expected setup to leave backups running, got: #{context.report}"

        {:ok, context}
      end

      then_ "the report makes no claim about monitoring either way", context do
        refute context.report =~ ~r/monitor/i,
               "setup does not do uptime monitoring, so its status must not mention it — " <>
                 "present reads as a promise nobody keeps, missing reads as a complaint " <>
                 "about work that is not owed. Got: #{context.report}"

        {:ok, context}
      end
    end
  end
end
