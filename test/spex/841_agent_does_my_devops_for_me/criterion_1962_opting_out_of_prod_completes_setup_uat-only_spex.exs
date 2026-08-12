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

  @cassette "841_1962_uat_only_complete"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_uat_only
  setup :provider_credentials_on_file
  setup :connect_providers
  # sops and age are real binaries reading real files. The default fixture's
  # memory environment is invisible to them, so the server step's write of
  # DATABASE_URL into envs/<env>.enc.env landed nowhere sops could see and it
  # exited 100 with "cannot operate on non-existent file".
  setup :real_working_directory

  spex "Opting out of prod completes setup UAT-only" do
    scenario "production is off, and setup still reaches done" do
      given_ "Sam has turned production off and UAT is provisioned", context do
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

        # Production is off from `setup :devops_uat_only`. UAT is provisioned by
        # running setup — the criterion is about what is true afterwards, so
        # something has to make it true.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        with_full_cassette @cassette <> "_setup" do
          {:reply, _response, _frame} =
            RunDevopsSetup.execute(%{project_id: to_string(context.project.id)}, frame)
        end

        {:ok, Map.put(context, :frame, frame)}
      end

      when_ "the agent asks whether setup is complete", context do
        {:reply, response, _frame} =
          with_provider_cassette(@cassette, fn ->
            DevopsStatus.execute(%{}, %Frame{assigns: %{current_scope: context.scope}})
          end)

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
