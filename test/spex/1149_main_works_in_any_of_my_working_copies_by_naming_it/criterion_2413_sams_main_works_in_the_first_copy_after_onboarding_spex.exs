defmodule CodeMySpecSpex.Story1149.Criterion2413Spex do
  @moduledoc "Main works in the first copy after it appears without restarting."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.AttachmentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam's Main works in the first copy after onboarding", criterion: 2413 do
    scenario "Main can use the first copy created after Main starts" do
      given_ "Main is running before the project's first working copy appears", context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main runs a command naming the first working copy", context do
        result = AttachmentHelpers.bash(context, context.one, "pwd")
        {:ok, Map.put(context, :command_result, result)}
      end

      then_ "the command runs in the new copy and returns to Main", context do
        assert context.command_result.exit_status == 0
        assert String.trim(context.command_result.output) == context.one.root
        {:ok, context}
      end

      then_ "Main keeps its identity and conversation without a restart", context do
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
