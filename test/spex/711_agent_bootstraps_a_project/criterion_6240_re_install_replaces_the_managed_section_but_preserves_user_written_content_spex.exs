defmodule CodeMySpecSpex.Story711.Criterion6240Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6240 — Re-install replaces the managed section but preserves user-written content.

  When CLAUDE.md already exists with user-written content above and below
  the managed-section markers, re-running `install_claude_md` replaces
  only the content between the markers — user-written content above and
  below survives untouched.

  Surface: `InstallClaudeMd` MCP tool. The tool reads and writes through
  `scope.environment`, so the spec seeds and observes CLAUDE.md via
  `CodeMySpec.Environments`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Bootstrap.Content
  alias CodeMySpec.McpServers.Bootstrap.Tools.InstallClaudeMd

  setup :register_log_in_setup_account
  setup :setup_active_project

  @user_above "# My Project\n\nSome custom prose above the managed section.\n\n"
  @user_below "\n## Custom Footer\n\nHand-written notes from the user.\n"
  @stale_managed "Old managed section content that should be replaced."

  spex "install_claude_md writes the managed CLAUDE.md section between explicit markers" do
    scenario "Re-install replaces the managed section but preserves user-written content" do
      given_ "CLAUDE.md exists with user-written content above and below the managed markers",
             context do
        start_marker = Content.claude_md_start_marker()
        end_marker = Content.claude_md_end_marker()

        existing =
          @user_above <>
            start_marker <> "\n" <> @stale_managed <> "\n" <> end_marker <> @user_below

        :ok = Environments.write_file(context.environment, "CLAUDE.md", existing)

        {:ok, context}
      end

      when_ "the agent calls install_claude_md again", context do
        frame = %Frame{assigns: %{working_dir: context.scope.cwd, current_scope: context.scope}}
        {:reply, response, _frame} = InstallClaudeMd.execute(%{}, frame)
        {:ok, Map.put(context, :install_response, response)}
      end

      then_ "the user-written content above and below the markers is unchanged", context do
        assert {:ok, contents} = Environments.read_file(context.environment, "CLAUDE.md")

        assert String.contains?(contents, @user_above),
               "expected user-written content above the managed section to survive, got:\n#{contents}"

        assert String.contains?(contents, @user_below),
               "expected user-written content below the managed section to survive, got:\n#{contents}"

        {:ok, Map.put(context, :claude_md_contents, contents)}
      end

      and_ "the managed section between the markers reflects the freshly generated content",
           context do
        contents = context.claude_md_contents

        refute String.contains?(contents, @stale_managed),
               "expected the stale managed section to be replaced, got:\n#{contents}"

        assert String.contains?(contents, Content.claude_md_start_marker()),
               "expected start marker in CLAUDE.md, got:\n#{contents}"

        assert String.contains?(contents, Content.claude_md_end_marker()),
               "expected end marker in CLAUDE.md, got:\n#{contents}"

        {:ok, context}
      end
    end
  end
end
