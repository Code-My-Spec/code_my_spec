defmodule CodeMySpecSpex.Story1149.Criterion2420Spex do
  @moduledoc "Main can read a newly added copy without connecting first."
  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.AttachmentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam's Main needs no connect step before working in a new copy", criterion: 2420 do
    scenario "Main reads a copy added after its conversation began" do
      given_ "Main is already running when another working copy is added", context do
        context = AttachmentHelpers.setup(context)
        copy = AttachmentHelpers.copy(context.tool_context.scope, "new")
        {:ok, Map.put(context, :new_copy, copy)}
      end

      when_ "Main reads the new copy by working_copy_id", context do
        result = AttachmentHelpers.read(context, context.new_copy, "identity.txt")
        {:ok, Map.put(context, :read_result, result)}
      end

      then_ "the read runs in the new copy without a connect or attach call", context do
        assert context.read_result =~ "new"
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
