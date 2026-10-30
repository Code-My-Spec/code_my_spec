defmodule CodeMySpecSpex.Story1149.Criterion2422Spex do
  @moduledoc "An offline working copy refuses a command without queuing it."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.AttachmentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam's Main gets a hard error when a copy is offline", criterion: 2422 do
    scenario "an offline copy does not queue a named command" do
      given_ "Main is running and the named copy goes offline", context do
        context = AttachmentHelpers.setup(context)
        AttachmentHelpers.mode(context.two, :offline)
        {:ok, context}
      end

      when_ "Main runs a command naming the offline copy", context do
        result =
          AttachmentHelpers.result(context, "bash", %{
            working_copy_id: context.two.id,
            command: "touch queued-command"
          })

        {:ok, Map.put(context, :command_result, result)}
      end

      then_ "the call fails immediately and the command never runs after reconnection", context do
        assert {:error, :harness_unreachable} = context.command_result
        AttachmentHelpers.mode(context.two, :online)
        assert AttachmentHelpers.read(context, context.two, "identity.txt") =~ "remote"
        AttachmentHelpers.assert_file_absent(context.two, "queued-command")
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
