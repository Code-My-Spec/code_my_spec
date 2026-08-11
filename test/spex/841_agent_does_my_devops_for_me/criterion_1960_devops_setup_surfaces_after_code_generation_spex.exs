defmodule CodeMySpecSpex.Story841.Criterion1960Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1960 — DevOps setup surfaces after code generation.

  Code that exists and is not deployed is not finished. Once there is something
  to run, the agent has to be told infrastructure is outstanding rather than
  waiting to be asked.

  Surface: `devops_status` MCP tool. This is what the agent calls now — the
  requirement graph used to carry `devops_setup` as a node and no longer does
  (d207ad38), so the surfacing has to come from asking rather than from the
  graph handing out the next task.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Devops.Tools.DevopsStatus

  @cassette "841_1960_setup_outstanding"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :provider_credentials_on_file
  setup :connect_providers

  spex "DevOps setup surfaces after code generation" do
    scenario "there is code, and no infrastructure behind it" do
      given_ "the project has code generated and nothing provisioned", context do
        # There is something to run — that is the premise. Nothing is
        # provisioned because nothing has provisioned it; the project starts
        # that way and this scenario never runs setup.
        :ok =
          CodeMySpec.Environments.write_file(
            context.environment,
            "lib/story841_generated.ex",
            "defmodule Story841.Generated do\n  def run, do: :ok\nend\n"
          )

        {:ok, context}
      end

      when_ "the agent asks whether the infrastructure exists", context do
        {:reply, response, _frame} =
          with_provider_cassette(@cassette, fn ->
            DevopsStatus.execute(%{}, %Frame{assigns: %{current_scope: context.scope}})
          end)

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "it says setup is not complete", context do
        assert context.report =~ "Setup is not complete",
               "expected an unprovisioned project to report outstanding setup, got: #{context.report}"

        {:ok, context}
      end

      then_ "it names the steps with nothing behind them", context do
        assert context.report =~ "Missing",
               "expected the outstanding steps to be listed rather than only counted"

        assert context.report =~ ~r/- .+\/(repository|server|domain|dns|deploy)/,
               "expected named steps so the agent knows what to run, got: #{context.report}"

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
