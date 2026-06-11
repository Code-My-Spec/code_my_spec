defmodule CodeMySpecSpex.Story711.Criterion6239Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6239 — First install creates CLAUDE.md with the managed section.

  When the agent calls `install_claude_md` against a working directory with
  no existing CLAUDE.md, the tool writes a new file at the project root
  whose contents include the managed-section start and end markers.

  Surface: `InstallClaudeMd` MCP tool. The tool reads and writes through
  `scope.environment`, so the spec observes the in-memory environment via
  `CodeMySpec.Environments`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Bootstrap.Content
  alias CodeMySpec.McpServers.Bootstrap.Tools.InstallClaudeMd

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "install_claude_md writes the managed CLAUDE.md section between explicit markers" do
    scenario "First install creates CLAUDE.md with the managed section" do
      given_ "the working directory has no CLAUDE.md", context do
        refute Environments.file_exists?(context.environment, "CLAUDE.md"),
               "expected CLAUDE.md to not exist before install"

        {:ok, context}
      end

      when_ "the agent calls install_claude_md", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        {:reply, response, _frame} = InstallClaudeMd.execute(%{}, frame)
        {:ok, Map.put(context, :install_response, response)}
      end

      then_ "CLAUDE.md exists at the project root", context do
        assert {:ok, contents} = Environments.read_file(context.environment, "CLAUDE.md"),
               "expected CLAUDE.md to exist after install"

        {:ok, Map.put(context, :claude_md_contents, contents)}
      end

      and_ "its contents include the managed-section start and end markers", context do
        contents = context.claude_md_contents

        assert String.contains?(contents, Content.claude_md_start_marker()),
               "expected start marker in CLAUDE.md, got:\n#{contents}"

        assert String.contains?(contents, Content.claude_md_end_marker()),
               "expected end marker in CLAUDE.md, got:\n#{contents}"

        {:ok, context}
      end
    end
  end
end
