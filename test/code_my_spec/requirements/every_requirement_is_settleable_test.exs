defmodule CodeMySpec.Requirements.EveryRequirementIsSettleableTest do
  @moduledoc """
  dfb8ef8f — a requirement can be added to the graph in two places
  (`RequirementDefinitionData`'s template, `story_execution.ex`'s
  `@completion_names`) and silently never settled by any event, forever,
  because a third registry (`Handlers`'s `@requirement_profiles` /
  `@delegate_requirements`) has no entry for it.

  `story_changed` and its siblings are *handled* event kinds: handling one
  discards the fallback safe-recompute for everything it can move, on the
  documented premise that `settle/3` covers all of it. A requirement missing
  from both registries is not marked stale by that path — it keeps whatever
  verdict it happened to have the first time anything computed it, with
  nothing ever correcting it again. Measured live: two stories stuck
  `STALE READ` permanently on exactly this gap for `questions_answered`.

  This is `every_declared_event_is_applied_or_counted_test`'s counterpart on
  the other axis: that one asks whether every event kind is accounted for;
  this asks whether every requirement is.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.Handlers
  alias CodeMySpec.Requirements.Registry
  alias CodeMySpec.Requirements.RequirementDefinitionData, as: Definitions

  # Requirements settled by a route other than `Handlers.apply_event/3`, with
  # the reason each is exempt. Empty for now — `implementation_file` turned
  # out to already carry a `@requirement_profiles` entry (`[:files]`), so
  # nothing currently needs one; kept as a real map, not deleted, because the
  # next name that genuinely is settled some other way should have a reason
  # written here rather than the test being loosened to `true`.
  # A copy's file verdicts are its overlay: reported by its harness or computed
  # from its files on read (`CopyOverlay.verdicts_at/1`), never settled here.
  @copy_verdict "a copy's file verdict, read from its overlay (`Handlers.copy_verdicts/1`)"

  # A copy's issues leave out those on stories placed elsewhere: its three gates
  # are settled when its graph is read (`Handlers.gate_verdicts/1`).
  @gate "a copy's placement gate, settled on read (`Handlers.gate_verdicts/1`)"

  @not_via_handlers %{
    "dependencies_met" =>
      "a container's dependency junction: `check_type: :always`, so no event can move it",
    "implementation_file" => @copy_verdict,
    "bdd_specs_exist" => @copy_verdict,
    "technical_strategy" => @copy_verdict,
    "code_generation" => @copy_verdict,
    "qa_journey_execute" => @copy_verdict,
    "issues_triaged" => @gate,
    "issues_resolved" => @gate
  }

  @component_types ~w(context coordination_context live_context controller schema
                      behaviour json liveview liveview_component other)

  defp all_requirement_names do
    component =
      Enum.flat_map(@component_types, fn type ->
        Registry.get_requirements_for_type(type)
      end)

    (Definitions.project_requirements() ++ Definitions.story_requirements() ++ component)
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  test "every requirement definition is reachable from a handled event, or explicitly not" do
    settleable = MapSet.new(Handlers.settleable_requirement_names())

    unaccounted =
      all_requirement_names()
      |> Enum.reject(&(MapSet.member?(settleable, &1) or Map.has_key?(@not_via_handlers, &1)))

    assert unaccounted == [],
           """
           These requirement names exist in the graph but have no entry in
           Handlers.@requirement_profiles or @delegate_requirements, and no exemption
           here:

           #{Enum.map_join(unaccounted, "\n", &"  * #{&1}")}

           This is not merely untested — for any event kind already handled (see
           Handlers.handled_kinds/0), it means the requirement is silently never
           re-settled after its first computation, forever. Add a `settle/3` clause and
           a row in `@requirement_profiles` (or `@delegate_requirements` for a
           project-wide rollup), or add it to `@not_via_handlers` here with the reason
           it is settled some other way.
           """
  end

  test "nothing in @not_via_handlers is actually settleable now" do
    settleable = MapSet.new(Handlers.settleable_requirement_names())
    stale = Enum.filter(Map.keys(@not_via_handlers), &MapSet.member?(settleable, &1))

    assert stale == [],
           "settleable now, so remove from @not_via_handlers: #{Enum.join(stale, ", ")}"
  end
end
