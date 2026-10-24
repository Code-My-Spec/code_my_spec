defmodule CodeMySpecSpex.Story1148.Criterion2410Spex do
  @moduledoc "Main discovers copies by device. In-process device transport simulation; not a two-host drill."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.AttachmentHelpers
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Main discovers copies by device", criterion: 2410 do
    scenario "Main discovers copies by device" do
      given_ "Main has a conversation and authorized copies on distinct devices", context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main exercises the attachment through its registered tools", context do
        AttachmentHelpers.exercise(context, 2410)
        {:ok, context}
      end

      then_ "the tool results satisfy the scenario without moving Main", context do
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
