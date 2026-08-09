defmodule CodeMySpecSpex.Story841.Criterion1959Spex do
  @moduledoc """
  Story 841 — Agent does my DevOps for me
  Criterion 1959 — Sam sees every resource in his own consoles.

  The ownership contract. Everything setup makes lives in Sam's own provider
  accounts, so he can find it, audit it, and take it with him. A resource held
  on the platform's side would be invisible to him and impossible to leave.

  Surface: `devops_status` MCP tool. It answers from the providers rather than
  from a record file, which is the only way "it is in his console" can be
  checked at all — a local row proves nothing about whose account it is in.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Devops.Tools.{DevopsStatus, RunDevopsSetup}

  @cassette "841_1959_resources_in_own_accounts"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "Sam sees every resource in his own consoles" do
    scenario "the report reads the providers Sam owns" do
      given_ "Sam has had setup run against his own provider accounts", context do
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
            DevopsStatus.execute(%{}, context.frame)
          end)

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "every resource it names is located in Sam's own account", context do
        refute context.report =~ "codemyspec.com",
               "expected no resource to live on the platform's own domain, got: #{context.report}"

        refute context.report =~ "platform",
               "a resource held platform-side is one Sam cannot audit or take with him"

        {:ok, context}
      end

      then_ "the answer comes from the providers, not from a claim on file", context do
        refute context.report =~ "setup.md",
               "expected the report to be read from providers rather than a record file"

        assert context.report =~ ~r/Setup is (not )?complete|Cannot say/,
               "expected a verdict derived from what the providers actually hold, got: #{context.report}"

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
