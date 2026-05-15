defmodule CodeMySpecSpex.Story711.Criterion6242Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6242 — Install errors with a project-root directive when mix.exs is absent.

  When the working directory has no `mix.exs` and the agent calls
  `install_agents_md`, the response is an error that names `mix.exs`
  and instructs the agent to run the tool from the project root.

  Surface: `InstallAgentsMd` MCP tool. Error text is rendered into the
  response body via `BootstrapMapper.error/1`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Bootstrap.Tools.InstallAgentsMd

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "install_agents_md writes .code_my_spec/AGENTS.md derived from the project's mix.exs app name" do
    scenario "Install errors with a project-root directive when mix.exs is absent" do
      given_ "the working directory has no mix.exs", context do
        mix_exs = Path.join(context.scope.cwd, "mix.exs")
        File.rm(mix_exs)
        refute File.exists?(mix_exs), "expected mix.exs to be absent before install"
        {:ok, context}
      end

      when_ "the agent calls install_agents_md", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        {:reply, response, _frame} = InstallAgentsMd.execute(%{}, frame)
        {:ok, Map.put(context, :install_response, response)}
      end

      then_ "the response is an error", context do
        body = response_text(context.install_response)

        assert body =~ ~r/error|failed|not found|cannot/i,
               "expected an error response, got: #{inspect(body)}"

        {:ok, Map.put(context, :response_body, body)}
      end

      and_ "the error message names mix.exs and instructs the agent to run from the project root",
           context do
        body = context.response_body

        assert body =~ ~r/mix\.exs/,
               "expected error to name mix.exs, got: #{inspect(body)}"

        assert body =~ ~r/project root/i,
               "expected error to instruct running from project root, got: #{inspect(body)}"

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
