defmodule CodeMySpecSpex.Story711.Criterion6241Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6241 — Install writes AGENTS.md when mix.exs is present.

  When the working directory has a mix.exs declaring an app name and the
  agent calls `install_agents_md`, the tool writes
  `.code_my_spec/AGENTS.md` and the file body references the extracted
  app name.

  Surface: `InstallAgentsMd` MCP tool. The tool reads `mix.exs` directly
  and writes AGENTS.md to the real filesystem under `context.scope.cwd`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Bootstrap.Tools.InstallAgentsMd

  setup :register_log_in_setup_account
  setup :setup_active_project

  @app_name_atom :spex_bootstrap_app

  spex "install_agents_md writes .code_my_spec/AGENTS.md derived from the project's mix.exs app name" do
    scenario "Install writes AGENTS.md when mix.exs is present" do
      given_ "the working directory has a mix.exs declaring an app name", context do
        mix_exs = Path.join(context.scope.cwd, "mix.exs")

        File.write!(mix_exs, """
        defmodule SpexBootstrapApp.MixProject do
          use Mix.Project
          def project, do: [app: :#{@app_name_atom}, version: "0.0.1"]
        end
        """)

        {:ok, Map.put(context, :mix_exs, mix_exs)}
      end

      when_ "the agent calls install_agents_md", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        {:reply, response, _frame} = InstallAgentsMd.execute(%{}, frame)
        {:ok, Map.put(context, :install_response, response)}
      end

      then_ ".code_my_spec/AGENTS.md exists", context do
        agents_md = Path.join([context.scope.cwd, ".code_my_spec", "AGENTS.md"])
        assert File.exists?(agents_md), "expected AGENTS.md at `#{agents_md}` after install"
        {:ok, Map.put(context, :agents_md_contents, File.read!(agents_md))}
      end

      and_ "the file contents reference the app name extracted from mix.exs", context do
        contents = context.agents_md_contents
        app_name = Atom.to_string(@app_name_atom)

        assert String.contains?(contents, app_name),
               "expected AGENTS.md to reference app name `#{app_name}`, got:\n#{contents}"

        {:ok, context}
      end
    end
  end
end
