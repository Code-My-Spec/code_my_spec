defmodule CodeMySpecSpex.Story964.Criterion2938Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2938 — Asking about dispatched work gets a report.

  Rule: Once an epic is handed over, the main agent reports on that work rather
  than doing it.

  ## What this can and cannot assert

  The criterion says the main agent *tells me* how it is going, in language that
  assumes no code. Whether a model phrases something well is not a property code
  can hold, and a spec that asserted on its wording would be asserting on a
  sentence that is different every run.

  What is code's to hold is the half underneath: **the main agent can find out
  without doing the work.** The status of an epic it dispatched has to be
  readable from where the main agent stands, or the report is a guess however
  well it is phrased.

  So this drives the surface the main agent reads. The wording is left to QA,
  where a person can judge it, and that split is deliberate rather than a gap.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.EpicHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Once an epic is handed over, the main agent reports on that work rather than doing it" do
    scenario "Asking about dispatched work gets a report" do
      given_ :synced_context_component

      given_ "an epic being built on another working copy", context do
        context = EpicHelpers.dispatch_one(context, "Work happening elsewhere", stories: 2)

        {:ok, context}
      end

      when_ "the main agent looks at how it is going", context do
        report = EpicHelpers.progress(context)

        {:ok, Map.put(context, :report, report)}
      end

      then_ "the epic's state is there to be reported", context do
        assert context.report.epics != [],
               "the main agent can see no dispatched epics, so anything it says about " <>
                 "them is invented"

        epic = hd(context.report.epics)

        assert epic.status == "dispatched",
               "the epic reads as #{epic.status} rather than dispatched"

        assert epic.working_copy_id,
               "the report does not say where the work is happening"

        {:ok, context}
      end

      then_ "and it did not have to do the work to find out", context do
        assert context.report.source == :record,
               "the main agent derived its report by running something rather than by " <>
                 "reading what the dispatched agent recorded. Reporting on work it is not " <>
                 "doing is the whole point of the hand-off."

        {:ok, context}
      end
    end
  end
end
