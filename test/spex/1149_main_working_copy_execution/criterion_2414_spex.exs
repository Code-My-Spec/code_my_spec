defmodule CodeMySpecSpex.Story1149.Criterion2414Spex do
  @moduledoc "Authorized attachment permits work. In-process device transport simulation; not a two-host drill."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.AttachmentHelpers
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Authorized attachment permits work", criterion: 2414 do
    scenario "Authorized attachment permits work" do
      given_ "Main has a conversation and authorized copies on distinct devices", context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main works in the copies it names through its registered tools", context do
        AttachmentHelpers.exercise(context, 2414)
        {:ok, context}
      end

      then_ "the tool results satisfy the scenario without moving Main", context do
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
