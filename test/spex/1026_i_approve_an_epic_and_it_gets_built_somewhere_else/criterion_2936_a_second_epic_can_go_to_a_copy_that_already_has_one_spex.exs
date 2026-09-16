defmodule CodeMySpecSpex.Story964.Criterion2936Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2936 — A second epic can go to a copy that already has one.

  Rule: One working copy may hold more than one epic.

  John, on where an epic runs: *"the agent decides. If an existing working copy
  and agent is appropriate — for example I've had you doing all the harness work
  — it gets assigned there, or a fresh one at the agent's discretion."* And,
  separately: *"you might just leave this guy open for five or ten, who knows."*

  So continuity of context is a reason to reuse a copy, not an accident to be
  cleaned up. A rule of one-epic-per-checkout would throw away exactly what
  makes the second epic cheaper than the first, and would mint checkouts until
  the machine ran out.

  This asserts the *permission*, not the choice. Which copy an epic lands on is
  the agent's call and is deliberately not pinned here.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.EpicHelpers
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One working copy may hold more than one epic" do
    scenario "A second epic can go to a copy that already has one" do
      given_ :synced_context_component

      given_ "a working copy that has already been given an epic", context do
        context = EpicHelpers.dispatch_one(context, "The first epic", stories: 1)

        {:ok, context}
      end

      when_ "I agree to build another", context do
        context = EpicHelpers.dispatch_one(context, "The second epic", stories: 1)

        {:ok, _live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it can go to the same copy", context do
        copies =
          ~r/data-test="epic-working-copy"[^>]*data-working-copy-id="([^"]+)"/
          |> Regex.scan(context.html)
          |> Enum.map(fn [_, id] -> id end)

        assert length(copies) == 2,
               "two epics were dispatched and #{length(copies)} name a working copy"

        assert Enum.uniq(copies) |> length() == 1,
               "the second epic was forced onto a different checkout. Continuity of " <>
                 "context is the reason to reuse one — it is what makes the second epic " <>
                 "cheaper than the first — and a copy per epic mints checkouts until the " <>
                 "machine runs out."

        {:ok, context}
      end
    end
  end
end
