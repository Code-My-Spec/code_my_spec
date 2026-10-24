defmodule CodeMySpecSpex.Story1148.Criterion2419Spex do
  @moduledoc "Disconnect cancels attachment work only. In-process device transport simulation; not a two-host drill."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.AttachmentHelpers
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Disconnect cancels attachment work only", criterion: 2419 do
    scenario "Disconnect cancels attachment work only" do
      given_ "Main has a conversation and authorized copies on distinct devices", context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main exercises the attachment through its registered tools", context do
        AttachmentHelpers.exercise(context, 2419)
        {:ok, context}
      end

      then_ "the tool results satisfy the scenario without moving Main", context do
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
