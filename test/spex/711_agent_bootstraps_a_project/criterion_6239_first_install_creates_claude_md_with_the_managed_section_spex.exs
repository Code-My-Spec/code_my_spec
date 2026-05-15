defmodule CodeMySpecSpex.Story711.Criterion6239Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6239 — First install creates CLAUDE.md with the managed section.

  When the agent calls `install_claude_md` against a working directory with
  no existing CLAUDE.md, the tool writes a new file at the project root
  whose contents include the managed-section start and end markers.

  Surface: `InstallClaudeMd` MCP tool. The tool writes to the real
  filesystem under `context.scope.cwd`, so assertions read back via
  `File`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Bootstrap.Content
  alias CodeMySpec.McpServers.Bootstrap.Tools.InstallClaudeMd

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "install_claude_md writes the managed CLAUDE.md section between explicit markers" do
    scenario "First install creates CLAUDE.md with the managed section" do
      given_ "the working directory has no CLAUDE.md", context do
        claude_md = Path.join(context.scope.cwd, "CLAUDE.md")
        refute File.exists?(claude_md), "expected `#{claude_md}` to not exist before install"
        {:ok, context}
      end

      when_ "the agent calls install_claude_md", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        {:reply, response, _frame} = InstallClaudeMd.execute(%{}, frame)
        {:ok, Map.put(context, :install_response, response)}
      end

      then_ "CLAUDE.md exists at the project root", context do
        claude_md = Path.join(context.scope.cwd, "CLAUDE.md")
        assert File.exists?(claude_md), "expected CLAUDE.md at `#{claude_md}` after install"
        {:ok, Map.put(context, :claude_md_contents, File.read!(claude_md))}
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
