defmodule CodeMySpecSpex.Story1149.Criterion2419Spex do
  @moduledoc "Coding and QA keep their assignments while Main works in their copy."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.AttachmentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam's Coding and QA keep running in the copy Main works in", criterion: 2419 do
    scenario "Main's calls leave Coding and QA active in their assigned copy" do
      given_ "Coding and QA are active in Sam's laptop copy", context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main reads, edits and runs a command naming that copy", context do
        assert AttachmentHelpers.read(context, context.one, "identity.txt") =~ "laptop"

        AttachmentHelpers.work(context, context.one, "edit", %{
          file_path: "identity.txt",
          old_string: "laptop",
          new_string: "Main helped"
        })

        result = AttachmentHelpers.bash(context, context.one, "pwd")
        {:ok, Map.put(context, :command_result, result)}
      end

      then_ "Main receives results from the named copy", context do
        assert AttachmentHelpers.read(context, context.one, "identity.txt") =~ "Main helped"
        assert context.command_result.exit_status == 0
        assert String.trim(context.command_result.output) == context.one.root
        {:ok, context}
      end

      then_ "Coding and QA keep their assignments and sessions", context do
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
