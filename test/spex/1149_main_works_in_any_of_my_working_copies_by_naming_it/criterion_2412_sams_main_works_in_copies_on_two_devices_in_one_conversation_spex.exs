defmodule CodeMySpecSpex.Story1149.Criterion2412Spex do
  @moduledoc "Main works in copies on two devices in one conversation."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.AttachmentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam's Main works in copies on two devices in one conversation", criterion: 2412 do
    scenario "Main names each device's copy without changing conversations" do
      given_ "Main has one conversation and two authorized copies on different devices",
             context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main names each copy on successive tool calls", context do
        laptop = AttachmentHelpers.read(context, context.one, "identity.txt")
        remote = AttachmentHelpers.read(context, context.two, "identity.txt")
        {:ok, Map.merge(context, %{laptop_result: laptop, remote_result: remote})}
      end

      then_ "each call returns the named copy's content", context do
        assert context.laptop_result =~ "laptop"
        assert context.remote_result =~ "remote"
        {:ok, context}
      end

      then_ "Main's conversation and the other agents remain in place", context do
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
