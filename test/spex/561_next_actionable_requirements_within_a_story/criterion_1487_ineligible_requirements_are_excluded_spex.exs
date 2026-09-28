defmodule CodeMySpecSpex.Story561.Criterion3589Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements Within a Story
  Criterion 3589 — Ineligible requirements are excluded
  """
  use CodeMySpecSpex.Case
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Ineligible requirements are excluded", criterion: 1487 do
    scenario "Ineligible requirements are excluded" do
      given_ "a story where some requirements belong to this role and some do not", context do
        context = context |> Slice.base() |> Slice.child()

        [criterion | _] =
          CodeMySpecSpex.StoryHelpers.fetch(context.scope, context.story.id).criteria

        :ok =
          CodeMySpec.Environments.delete_file(
            context.environment,
            CodeMySpecSpex.Fixtures.spec_file_path(context.story, criterion)
          )

        {:ok, CodeMySpecSpex.GraphGivens.sync(context)}
      end

      when_ "the agent asks what to work on", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "only the requirements this role can act on come back", context do
        Slice.assert_active(context.answer, context, "ready")
        assert context.answer =~ "bdd_specs_exist"
        refute context.answer =~ "requirement_name=`component_linked`"
        refute context.answer =~ "requirement_name=`three_amigos_complete`"
        refute Slice.offered?(context.answer, Slice.component(context, "Reservations.Booking").id)
        {:ok, context}
      end
    end
  end
end
