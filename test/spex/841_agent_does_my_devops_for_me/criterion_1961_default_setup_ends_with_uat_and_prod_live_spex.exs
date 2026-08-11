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
  setup :real_working_directory
  # The registry and database steps run for real against the fleet's app
  # box. Without this they SSH to the server address in the cassette, which
  # was released weeks ago — and `serve_registries/5` halts on that, so
  # nothing downstream records a resource and setup reports every step from
  # `server` onward as having nothing behind it.
  setup :fleet_box

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

        # The default plan is the subject, so it is set rather than inherited.
        # Nothing is provisioned because nothing has run yet — the `when_` is
        # the first thing in this scenario to touch a provider.
        :ok = CodeMySpecSpex.Fixtures.set_devops(context.scope, :prod)

        {:ok, context}
      end

      when_ "the agent runs setup and then asks what exists", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        report =
          with_provider_cassette(@cassette, fn ->
            {:reply, _run, _frame} =
              RunDevopsSetup.execute(%{project_id: to_string(context.project.id)}, frame)

            {:reply, status, _frame} = DevopsStatus.execute(%{}, frame)
            response_text(status)
          end)

        {:ok, Map.put(context, :report, report)}
      end

      then_ "setup reports complete", context do
        assert context.report =~ "Setup is complete",
               "expected the default plan to finish, got: #{context.report}"

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
