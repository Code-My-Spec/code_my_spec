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

  @cassette "841_1961_default_setup_uat_and_prod"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :provider_credentials_on_file
  setup :connect_providers
  # sops and age are real binaries reading real files. The default fixture's
  # memory environment is invisible to them, so the server step's write of
  # DATABASE_URL into envs/<env>.enc.env landed nowhere sops could see and it
  # exited 100 with "cannot operate on non-existent file".
  #
  # The drill checkout rather than `real_working_directory`, because the whole
  # plan includes the deploy: against the stub — a directory holding only a
  # `mix.exs` — it refused with "not deploy-ready: missing Dockerfile, missing
  # CI build workflow", and the ten steps behind it reported nothing.
  setup :drill_working_directory

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
        # Registered before anything provisions, so a run that dies partway
        # still returns its boxes.
        #
        # Hetzner's server limit on this account is 5 and two are permanently
        # John's, so a recording has three slots. None of story 841's
        # setup-running criteria returned any, so they accumulated *within a
        # single run*: the first took two, the second took the third, and every
        # one after it got `resource_limit_exceeded` — which then went into the
        # cassette as the story's expected behaviour. No amount of cleaning
        # between runs could have helped, because the exhaustion happens inside
        # one.
        tear_down_after(context.scope, [:server, :storage, :dns])
        tear_down_repository(context.project)

        # A domain, before the plan runs. Nothing in story 841 has ever set
        # one, so the domain step refused with "no domain set on the project"
        # and the twelve steps after it reported nothing behind them — which
        # reads as a setup that failed everywhere rather than one that stopped
        # at its second step.
        #
        # Its own subdomain, the way every other criterion that needs a domain
        # does it: the plan brings up `uat.` and the apex of whatever it is
        # given, and pointing that at `astralbi.com` itself would have teardown
        # removing records the zone actually uses.
        own_domain(context.project, "c1961.astralbi.com")

        # The default plan is the subject, so it is set rather than inherited.
        # Nothing is provisioned because nothing has run yet — the `when_` is
        # the first thing in this scenario to touch a provider.
        :ok = CodeMySpecSpex.Fixtures.set_devops(context.scope, :prod)

        {:ok, context}
      end

      when_ "the agent runs setup and then asks what exists", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        # Twice, with the borrowed grants refreshed in between.
        #
        # The whole sequence takes about fourteen minutes — two container
        # builds and two deploys — and Resend issues a token good for about
        # fifteen. The spex's copy cannot renew itself (see
        # `refresh_provider_grants/1`), so a single pass lost Resend partway
        # and halted with `:reauthorize_required` at email, leaving the seven
        # steps behind it with nothing behind them and no error against any.
        #
        # A second run is not a workaround: `RunDevopsSetup` resumes from where
        # it stopped, which is criterion 7963's subject and exactly what a
        # person does after a run is interrupted. Recording it in two segments
        # also keeps each cassette inside the token's life, which is how the
        # long recordings in this epic were split before.
        first =
          with_full_cassette @cassette <> "_first" do
            {:reply, run, _frame} =
              RunDevopsSetup.execute(%{project_id: to_string(context.project.id)}, frame)

            response_text(run)
          end

        refresh_provider_grants(context.scope)

        {run, report} =
          with_full_cassette @cassette do
            {:reply, run, _frame} =
              RunDevopsSetup.execute(%{project_id: to_string(context.project.id)}, frame)

            {:reply, status, _frame} = DevopsStatus.execute(%{}, frame)
            {first <> "\n\nthen, resumed: " <> response_text(run), response_text(status)}
          end

        # The run's own answer, kept rather than discarded. `RunDevopsSetup`
        # distinguishes complete from *paused* — a run waiting on a person,
        # which reports the instructions it is waiting on — and from halted at
        # a named step. Throwing that away left the status report as the only
        # evidence, and a paused run looks identical there to a finished one
        # that failed: a tail of steps with nothing behind them and no error
        # against any of them.
        {:ok, context |> Map.put(:report, report) |> Map.put(:run, run)}
      end

      then_ "setup reports complete", context do
        assert context.report =~ "Setup is complete",
               "expected the default plan to finish.\n\nThe run said: #{context.run}\n\n" <>
                 "The status says: #{context.report}"

        {:ok, context}
      end

      then_ "neither environment is left missing", context do
        refute context.report =~ ~r/Missing.*uat/s,
               "expected UAT to be live after the default plan, got: #{context.report}"

        refute context.report =~ ~r/Missing.*prod/s,
               "expected production to be live after the default plan — the default is not UAT-only"

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
