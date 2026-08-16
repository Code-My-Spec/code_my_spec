defmodule CodeMySpecSpex.Story841.Criterion1962Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1962 — Opting out of prod completes setup UAT-only.

  Turning production off has to mean setup can *finish*, not that it finishes
  with a permanent complaint about a step nobody asked for. A run that reads
  "incomplete" forever because of a deliberate choice is indistinguishable from
  one that failed.

  Surface: `devops_status` MCP tool with the project configured UAT-only.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Devops.Tools.{DevopsStatus, RunDevopsSetup}

  # The widget message travels over a real socket, and `connect/3` reads this.
  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_uat_only
  setup :fake_providers
  # A modelled shell over the memory filesystem, so a step reading what an
  # earlier step wrote finds it — `ssh-keygen -f path` leaves a key at `path`
  # and `sops set` puts a secret somewhere `sops decrypt` can read it back.
  setup :fake_working_directory

  spex "Opting out of prod completes setup UAT-only" do
    scenario "production is off, and setup still reaches done" do
      given_ "Sam has turned production off and UAT is provisioned", context do
        # A domain, before the plan runs — the same gap 1961 had. Without one
        # the domain step refuses with "no domain set on the project" and every
        # step behind it reports nothing, which reads as a setup broken
        # everywhere rather than one stopped at its fourth step.
        own_domain(context.project, "c1962.legwork.ca")

        # And a zone covering it: `ensure_domain` adopts a name the account
        # already manages and otherwise offers to buy it, so without this the
        # domain step pauses on "registering it costs money" — correctly, and
        # about something this criterion is not asking.
        zone_exists(context, "legwork.ca")

        # A checkout the deploy step accepts, written after the domain because
        # the generated `config/deploy.yml` names the host it deploys to.
        deploy_ready_checkout(context)

        # And a visitor who has used the widget. The widget step reports done
        # only on a message from the deployed site — nothing in the sequence
        # can manufacture one, so without this the run pauses there ("waiting
        # on a person, not broken") and the step behind it never runs. A
        # criterion asserting setup *finishes* has to say so; 973/8044 is where
        # the gate itself is proven.
        #
        # `uat.`, not the apex. With production off, UAT *is* the site:
        # `primary_environment/2` picks prod when there is one and the first
        # environment otherwise, and the step compares the message's origin
        # against the site it checked. Naming the apex here made the message
        # read as coming from somewhere else, which is exactly the distinction
        # the origin check exists to draw.
        visitor_message_from(context, "https://uat.c1962.legwork.ca")

        # Production is off from `setup :devops_uat_only`. UAT is provisioned by
        # running setup — the criterion is about what is true afterwards, so
        # something has to make it true.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          RunDevopsSetup.execute(%{project_id: to_string(context.project.id)}, frame)

        {:ok, Map.put(context, :frame, frame)}
      end

      when_ "the agent asks whether setup is complete", context do
        {:reply, response, _frame} =
          DevopsStatus.execute(%{}, %Frame{assigns: %{current_scope: context.scope}})

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "it reports complete", context do
        assert context.report =~ "Setup is complete",
               "expected UAT-only setup to be able to finish, got: #{context.report}"

        {:ok, context}
      end

      then_ "production is not held against it", context do
        refute context.report =~ "prod",
               "expected an environment Sam opted out of to be absent, not listed as missing"

        {:ok, context}
      end

      then_ "and production was not built either", context do
        # Asked of the provider, because the report cannot answer it. This run
        # *did* build a production server — `Steps.environments/2` fanned out
        # over the seeded rows and never read the setting that says "stand up
        # staging only" — and every step of it succeeded, so `devops_status`
        # said "Setup is complete" and the assertion above passed. Opting out
        # was costing a box nobody asked for, invisibly.
        #
        # UAT-only means uat only. Against real providers the difference is a
        # server somebody pays for, a DNS record and a database.
        names = server_names(context)

        refute Enum.any?(names, &String.ends_with?(&1, "-prod")),
               "expected no production server on a project set to UAT-only, got: #{inspect(names)}"

        assert Enum.any?(names, &String.ends_with?(&1, "-uat")),
               "expected UAT to be stood up, got: #{inspect(names)}"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
