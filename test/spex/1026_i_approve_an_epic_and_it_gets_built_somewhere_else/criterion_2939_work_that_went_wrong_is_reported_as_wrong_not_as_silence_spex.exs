defmodule CodeMySpecSpex.Story964.Criterion2939Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2939 — Work that went wrong is reported as wrong, not as silence.

  Rule: Once an epic is handed over, the main agent reports on that work rather
  than doing it.

  The failure this whole story can produce and no other criterion catches. An
  agent that died and an agent that is thinking both produce nothing, and if
  they are the same from where the main agent stands then "it is still going" is
  what gets said about work that stopped hours ago. The user finds out when they
  ask why it is taking so long.

  Story 962 made exactly this distinction inside one working copy — a turn that
  fails announces itself rather than going quiet. This is the same rule one
  level up: a *dispatched epic* whose agent failed must be distinguishable, at
  the surface the main agent reads, from one still being worked on.

  As with 2938, the wording of the report belongs to QA. What is asserted here
  is that the difference exists to be reported at all.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.EpicHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Once an epic is handed over, the main agent reports on that work rather than doing it" do
    scenario "Work that went wrong is reported as wrong, not as silence" do
      given_ :synced_context_component

      given_ "an epic whose agent has stopped without finishing", context do
        context = EpicHelpers.dispatch_one(context, "Work that will fail", stories: 1)
        EpicHelpers.agent_fails(context, "the checkout is gone")

        {:ok, context}
      end

      when_ "the main agent looks at how it is going", context do
        report = EpicHelpers.progress(context)

        {:ok, Map.put(context, :report, report)}
      end

      then_ "the epic reads as gone wrong rather than as in progress", context do
        epic = hd(context.report.epics)

        assert epic.status == "failed",
               "the epic reads as #{epic.status}. An agent that died and an agent that is " <>
                 "thinking both produce nothing, and if they look the same from here then " <>
                 "'still going' is what gets said about work that stopped hours ago."

        {:ok, context}
      end

      then_ "and it says what it means for the project", context do
        epic = hd(context.report.epics)

        assert is_binary(epic.reason) and epic.reason != "",
               "the epic is marked failed and carries no reason, so the report can say " <>
                 "that something went wrong and not what — which sends the user to look " <>
                 "for it themselves, in a checkout they should not have to know about."

        {:ok, context}
      end
    end
  end
end
