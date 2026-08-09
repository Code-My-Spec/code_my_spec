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

  @cassette "841_1969_rebuild_from_scratch"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "The repo can rebuild the infrastructure from scratch" do
    scenario "the resources are gone, and setup makes them again" do
      given_ "the repo holds its deployment configuration, and nothing is provisioned",
             context do
        # "From scratch" is the premise, so nothing is provisioned — this
        # scenario never runs setup before the `when_`. What has to be
        # established is the other half: the repo actually carries the
        # configuration a rebuild would read. If that only ever lived in a
        # console, there is nothing to rebuild from.
        :ok =
          CodeMySpec.Environments.write_file(
            context.environment,
            "config/deploy.uat.yml",
            "service: story841\nimage: story841\nproxy:\n  host: uat.example.com\n"
          )

        {:ok, context}
      end

      when_ "setup is run again from what the repo holds", context do
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
