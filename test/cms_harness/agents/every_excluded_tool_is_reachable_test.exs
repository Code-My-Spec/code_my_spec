defmodule CmsHarness.Agents.EveryExcludedToolIsReachableTest do
  @moduledoc """
  `LocalServer`'s rule, enforced: *a tool excluded from scripts and absent from
  the engine would be reachable by no route at all.*

  Three times a capability was added at the spine, excluded from `run_script`
  for a reason about scripts, and never carried by `Engine.tools/1` — so the
  door the exclusion sent the agent to was the one that had been shut. Each time
  the symptom was a model that looked disobedient:

    * `get_next_requirement` — "I can't call get_next_requirement in this
      session: it isn't available in the active tool catalog, despite being
      listed in the project guide." The agent was right.
    * `start_agent` / `assign_subagent` — an agent describing a hand-over in
      detail and never making one: "Nothing has been assigned yet: this session
      has no start_agent or assign_subagent tool available."
    * `ask_user` — every stop refusal printed "call `ask_user`" at an agent
      whose catalog did not contain it. It wrote its question into its reply
      instead, which reached nobody, and that read as ignoring an affordance.

  Writing this test found two more of the same shape that nobody had hit yet:
  `tap_out`, which `Menu.tap_out_offer/1` offers on every refusal inside the
  loop, and `show_in_panel`, which the dynamic-panel work is built on.

  So the rule gets a test rather than another comment. A new exclusion now has
  to say which side of the line it is on, in `@unreachable_on_purpose`, with the
  reason — and a capability added at the spine and forgotten here fails on the
  next run instead of on a person.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Engine
  alias CodeMySpec.CodeMode.Catalog

  # Excluded from scripts *and* deliberately not carried, each for a reason that
  # is about this agent rather than about scripts.
  @unreachable_on_purpose %{
    # An agent that asks is allowed to stop and the answer is dispatched to it
    # as a message. Polling needs a running agent, so it cannot be combined with
    # going quiet — the push replaces both of these rather than supplementing
    # them.
    "check_answer" => "answers are pushed to this agent, so there is nothing to poll for",
    "list_user_questions" => "same: its own questions come back to it without being listed"
  }

  defp carried do
    []
    |> Engine.tools()
    |> Enum.map(& &1.name())
    |> MapSet.new()
  end

  test "every tool a script may not call is either carried or excused" do
    carried = carried()

    unreachable =
      Catalog.excluded()
      |> Enum.reject(&(&1 in carried))
      |> Enum.reject(&Map.has_key?(@unreachable_on_purpose, &1))

    assert unreachable == [],
           """
           These tools are excluded from `run_script` and not carried by
           `Engine.tools/1`, so an Alloy agent has no route to them:

               #{Enum.join(unreachable, "\n    ")}

           Either add a `CmsHarness.Agents.Tools.*` module for each, or add it to
           `@unreachable_on_purpose` with the reason it is genuinely unavailable
           to this kind of agent. Do not add it to the excuse list to make this
           pass — every entry there is a promise the agent does not need it.
           """
  end

  # The excuse list is the dangerous half of this test: an entry that stops
  # being true silently turns a real gap into a documented one.
  test "nothing is excused that is also carried" do
    carried = carried()

    both = Enum.filter(Map.keys(@unreachable_on_purpose), &(&1 in carried))

    assert both == [],
           "carried and also excused, so the excuse is stale: #{Enum.join(both, ", ")}"
  end

  # The tools the menu tells an agent to *call*. A refusal that says to call a
  # tool the agent has not got is worse than one that names none: it reads as an
  # instruction and cannot be followed.
  #
  # `list_problems` is deliberately not here. It is reachable from a script, so
  # carrying it would break story 1038's rule — every carried schema is read on
  # every turn — and the fix was the sentence: the directive names the tool
  # rather than telling the agent to call it. Anything the menu does tell an
  # agent to call has to be something it holds.
  test "every tool the stop menu tells an agent to call is carried" do
    carried = carried()

    for tool <- ~w(get_next_requirement evaluate_task ask_user_question send_message tap_out) do
      assert tool in carried, "the stop menu says to call `#{tool}` and the agent cannot"
    end
  end
end
