defmodule CodeMySpecSpex.Story711.Criterion6255Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6255 — Unlinked working directory surfaces list_projects→init_project directive.

  When the agent calls `get_next_requirement` from a working directory
  with no `Project` row pointing at it, the MCP fall-through path runs
  `Init.command` and the returned prompt instructs the agent to:
    1. Call `list_projects` to see what's available.
    2. Then `init_project` with the chosen project_id.

  Surface: `CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement`.
  When no project resolves from the frame's working_dir,
  `validate_local_scope/1` errors and the tool falls back to
  `Init.command/2`. ExCliVcr replays `init_all_prereqs_pass.json` so the
  Elixir / Phoenix installer / Postgresql probes don't depend on the
  test host.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account

  spex "An unlinked working directory surfaces the link-project directive through MCP" do
    scenario "Unlinked working directory surfaces list_projects→init_project directive" do
      given_ "a working directory that satisfies the Phoenix shape but no project row points at it",
             context do
        {:ok, Map.put(context, :unlinked_dir, Fixtures.phoenix_shape_working_dir())}
      end

      given_ "the DB does have a project linked elsewhere (so list_projects has something to return)",
             context do
        _other_project = Fixtures.project_fixture_unlinked(context.scope)
        {:ok, context}
      end

      given_ "the user is OAuth-authenticated (so Init.Auth is satisfied)", context do
        _client_user = Fixtures.client_user_fixture(context.user)
        {:ok, context}
      end

      when_ "the agent calls get_next_requirement from the unlinked working dir",
            context do
        frame = %Frame{assigns: %{working_dir: context.unlinked_dir}}

        prompt_text =
          use_cmd_cassette "init_all_prereqs_pass", record: :none do
            {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
            response_text(response)
          end

        {:ok, Map.put(context, :prompt_text, prompt_text)}
      end

      then_ "the prompt instructs the agent to call list_projects", context do
        assert context.prompt_text =~ ~r/list_projects/,
               "expected prompt to mention list_projects, got:\n#{context.prompt_text}"

        {:ok, context}
      end

      and_ "the prompt instructs the agent to call init_project with the chosen project_id",
           context do
        assert context.prompt_text =~ ~r/init_project/,
               "expected prompt to mention init_project, got:\n#{context.prompt_text}"

        assert context.prompt_text =~ ~r/project_id/i,
               "expected prompt to mention the project_id parameter, got:\n#{context.prompt_text}"

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
