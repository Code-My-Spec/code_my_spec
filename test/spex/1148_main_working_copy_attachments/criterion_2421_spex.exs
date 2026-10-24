defmodule CodeMySpecSpex.Story1148.Criterion2421Spex do
  @moduledoc "Unauthorized copy is refused. In-process device transport simulation; not a two-host drill."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.AttachmentHelpers
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Unauthorized copy is refused", criterion: 2421 do
    scenario "Unauthorized copy is refused" do
      given_ "Main has a conversation and authorized copies on distinct devices", context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main exercises the attachment through its registered tools", context do
        AttachmentHelpers.exercise(context, 2421)
        {:ok, context}
      end

      then_ "the tool results satisfy the scenario without moving Main", context do
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
