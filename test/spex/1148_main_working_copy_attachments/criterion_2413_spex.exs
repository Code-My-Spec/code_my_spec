defmodule CodeMySpecSpex.Story1148.Criterion2413Spex do
  @moduledoc "Detached Main attaches its first copy. In-process device transport simulation; not a two-host drill."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.AttachmentHelpers
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Detached Main attaches its first copy", criterion: 2413 do
    scenario "Detached Main attaches its first copy" do
      given_ "Main has a conversation and authorized copies on distinct devices", context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main exercises the attachment through its registered tools", context do
        AttachmentHelpers.exercise(context, 2413)
        {:ok, context}
      end

      then_ "the tool results satisfy the scenario without moving Main", context do
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
