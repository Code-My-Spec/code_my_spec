defmodule CodeMySpecSpex.Story841.Criterion1961Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1961 — Default setup ends with UAT and prod live.

  The default plan is not a partial one. Left alone, setup finishes with both
  environments serving — Sam does not have to know that a second pass exists to
  get production.

  Surface: `run_devops_setup` MCP tool, then `devops_status` to ask the
  providers what is actually there. Asserting on the run's own return would let
  a run that reported success while building nothing pass.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Devops.Tools.{DevopsStatus, RunDevopsSetup}

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # sops and age are real binaries reading real files. The default fixture's
  # memory environment is invisible to them, so the server step's write of
  # DATABASE_URL into envs/<env>.enc.env landed nowhere sops could see and it
  # exited 100 with "cannot operate on non-existent file".
  #
  # The drill checkout rather than `real_working_directory`, because the whole
  # plan includes the deploy: against the stub — a directory holding only a
  # `mix.exs` — it refused with "not deploy-ready: missing Dockerfile, missing
  # CI build workflow", and the ten steps behind it reported nothing.
  setup :fake_working_directory

  # No `fleet_box`. It existed because the registry and database steps SSH to
  # the server address in the cassette, which was released weeks ago — but that
  # is a problem only while the shell half of this criterion goes unrecorded.
  # `with_full_cassette` records it, so replay reaches no box at all and
  # recording reaches the box it just made.
  #
  # Keeping it actively broke the build. `fleet_box` sets
  # `provisioning_step_opts[:run]` and nothing else, and `Remote.build/4` reads
  # both `:run` and `:deliver` — so `git archive | ssh` went to the real
  # builder while `cd /build` ran on the fleet's *app* container. The tree
  # landed on one machine and the build ran on another, which arrived as
  # `sh: cd: can't cd to /build: No such file or directory` after a delivery
  # that reported success. The fleet has a builder box of its own on :2222;
  # one `:run` key cannot name two different machines.

  spex "Default setup ends with UAT and prod live" do
    scenario "the default plan leaves both environments serving" do
      given_ "a project set to the default plan, with nothing provisioned", context do
        # A domain, before the plan runs. Nothing in story 841 has ever set
        # one, so the domain step refused with "no domain set on the project"
        # and the twelve steps after it reported nothing behind them — which
        # reads as a setup that failed everywhere rather than one that stopped
        # at its second step.
        own_domain(context.project, "c1961.legwork.ca")

        # And a zone that covers it, which is the premise the recorded version
        # got for free from John's real account. `ensure_domain` adopts a name
        # the account already manages and otherwise offers to *buy* it — so
        # without this the domain step pauses on "registering it costs money
        # and is not refundable", correctly, and the eleven steps behind it
        # report nothing. A criterion about the default plan finishing should
        # not turn on whether Sam owns his own domain; that is 970's subject.
        zone_exists(context, "legwork.ca")

        # After the domain, not in the setup chain: the generated
        # `config/deploy.yml` names the host it deploys to, and the deploy step
        # refuses a config pointing somewhere the project does not own. Written
        # before the domain was set, it named `example.com` and the step said
        # so.
        deploy_ready_checkout(context)

        # The default plan is the subject, so it is set rather than inherited.
        # Nothing is provisioned because nothing has run yet — the `when_` is
        # the first thing in this scenario to touch a provider.
        :ok = CodeMySpecSpex.Fixtures.set_devops(context.scope, :prod)

        {:ok, context}
      end

      when_ "the agent runs setup and then asks what exists", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        # One pass. The recorded version ran twice with the provider grants
        # refreshed in between, because the whole sequence takes about fourteen
        # minutes and Resend issues a token good for about fifteen — so a
        # single pass lost Resend partway and halted at email. Against fakes
        # there is no token, no expiry, and nothing to resume from.
        {:reply, run, _frame} =
          RunDevopsSetup.execute(%{project_id: to_string(context.project.id)}, frame)

        {:reply, status, _frame} = DevopsStatus.execute(%{}, frame)

        {:ok,
         context
         |> Map.put(:report, response_text(status))
         |> Map.put(:run, response_text(run))}
      end

      then_ "every step through the deploy has resources behind it", context do
        # "UAT and prod live" is the sequence through `deploy`: a repository,
        # keys, both boxes, the name, the records pointing at them, and the app
        # serving. `DevopsStatus` lists what is missing as `project/step`
        # lines, so a step absent from that list has resources behind it.
        #
        # Not "Setup is complete", which this asserted before. The steps after
        # deploy prove things a run cannot cause on its own — the widget's
        # proof is a message from the deployed site's own client, and it lands
        # wherever `CODEMYSPEC_WIDGET_URL` points. Recorded from a laptop that
        # is the dev server behind the tunnel, not the test database this run
        # watches, so the message arrives somewhere this spex cannot see. The
        # widget step pauses for it by design — "waiting on a person, not
        # broken" — and 973 has criteria for that claim already.
        #
        # John's call, 2026-08-16, asked directly: end 1961 at "uat and prod
        # are serving".
        for step <- ~w(repository secrets server domain dns deploy) do
          refute context.report =~ "/#{step}",
                 "expected #{step} to have resources behind it after the default plan.\n\n" <>
                   "The run said: #{context.run}\n\nThe status says: #{context.report}"
        end

        {:ok, context}
      end

      then_ "neither environment is left missing", context do
        # Asked of the provider rather than of the report. `DevopsStatus` lists
        # what is missing as `project/step` lines and never names an
        # environment, so `refute report =~ ~r/Missing.*uat/` — which is what
        # this asserted before — could not fail: there was no "uat" in the text
        # to find either way. A criterion whose whole subject is *both*
        # environments cannot rest on an assertion that passes vacuously.
        #
        # Two boxes is what "neither environment is left missing" means
        # concretely, and the default plan is exactly the claim that a run
        # nobody steered produces the second one.
        names = Enum.map(servers(context), & &1["name"])

        assert Enum.any?(names, &String.ends_with?(&1, "-uat")),
               "expected a UAT server after the default plan, got: #{inspect(names)}"

        assert Enum.any?(names, &String.ends_with?(&1, "-prod")),
               "expected a production server after the default plan — the default is not " <>
                 "UAT-only, got: #{inspect(names)}"

        {:ok, context}
      end
    end
  end
end
