defmodule CodeMySpecSpex.Story1149.Criterion2415Spex do
  @moduledoc "Copy identifiers cannot bypass attachment authorization. In-process device transport simulation; not a two-host drill."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.AttachmentHelpers
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Copy identifiers cannot bypass attachment authorization", criterion: 2415 do
    scenario "Copy identifiers cannot bypass attachment authorization" do
      given_ "Main has a conversation and authorized copies on distinct devices", context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main works in the copies it names through its registered tools", context do
        AttachmentHelpers.exercise(context, 2415)
        {:ok, context}
      end

      then_ "the tool results satisfy the scenario without moving Main", context do
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
