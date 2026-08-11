defmodule CodeMySpecSpex.Story841.Criterion1968Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1968 — Setup leaves backups running and monitors watching.

  "Stays there" is half the story's promise. Setup that provisions and walks
  away leaves Sam with an app nobody is watching and data nobody is copying —
  and he finds out about both at the worst possible moment.

  Surface: `devops_status` MCP tool. Backups and monitoring are steps like any
  other, so the question "is this actually in place" gets the same answer from
  the same place, read from the providers rather than from a claim.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Devops.Tools.{DevopsStatus, RunDevopsSetup}

  @cassette "841_1968_backups_and_monitors"

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

  spex "Setup leaves backups running and monitors watching" do
    scenario "setup has finished, and both are in place" do
      given_ "a project whose setup has run to completion", context do
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

        # Run, not asserted. Backups and monitors being in place is what the
        # criterion is about, so the run that would put them there has to
        # actually happen.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        with_provider_cassette(@cassette <> "_setup", fn ->
          {:reply, _response, _frame} =
            RunDevopsSetup.execute(%{project_id: to_string(context.project.id)}, frame)
        end)

        {:ok, Map.put(context, :frame, frame)}
      end

      when_ "the agent asks what infrastructure exists", context do
        {:reply, response, _frame} =
          with_provider_cassette(@cassette, fn ->
            DevopsStatus.execute(%{}, %Frame{assigns: %{current_scope: context.scope}})
          end)

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "backups are not among the missing", context do
        refute context.report =~ ~r/Missing.*backups/s,
               "expected setup to leave backups running, got: #{context.report}"

        {:ok, context}
      end

      then_ "monitoring is not among the missing", context do
        refute context.report =~ ~r/Missing.*monitoring/s,
               "expected setup to leave a monitor watching, got: #{context.report}"

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
