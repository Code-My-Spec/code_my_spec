defmodule CodeMySpecSpex.Story1149.Criterion2416Spex do
  @moduledoc "Available target returns command results. In-process device transport simulation; not a two-host drill."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.AttachmentHelpers
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Available target returns command results", criterion: 2416 do
    scenario "Available target returns command results" do
      given_ "Main has a conversation and authorized copies on distinct devices", context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main exercises the attachment through its registered tools", context do
        AttachmentHelpers.exercise(context, 2416)
        {:ok, context}
      end

      then_ "the tool results satisfy the scenario without moving Main", context do
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
