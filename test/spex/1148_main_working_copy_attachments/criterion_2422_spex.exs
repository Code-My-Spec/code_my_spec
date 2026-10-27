defmodule CodeMySpecSpex.Story1148.Criterion2422Spex do
  @moduledoc "Offline connect fails without queuing. In-process device transport simulation; not a two-host drill."
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.AttachmentHelpers
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Offline connect fails without queuing", criterion: 2422 do
    scenario "Offline connect fails without queuing" do
      given_ "Main has a conversation and authorized copies on distinct devices", context do
        {:ok, AttachmentHelpers.setup(context)}
      end

      when_ "Main works in the copies it names through its registered tools", context do
        AttachmentHelpers.exercise(context, 2422)
        {:ok, context}
      end

      then_ "the tool results satisfy the scenario without moving Main", context do
        AttachmentHelpers.unchanged(context)
        {:ok, context}
      end
    end
  end
end
