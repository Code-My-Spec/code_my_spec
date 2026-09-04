defmodule CodeMySpecSpex.Story964.Criterion3090Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 3090 — The same three take the next epic.

  Rule: A working copy comes up with its three agents, and the same three serve
  every epic it is given.

  The half of the roster rule that says the agents belong to the copy rather
  than to the work. John, 2026-09-04: *"if that working copy is assigned more
  work it's gonna be the same three agents."*

  Criterion 2936 already establishes that a copy may hold a second epic. This
  says what that costs: nothing. No new agents, because the three that are there
  are the ones that take it — which is the reason reuse is cheaper than a fresh
  copy, and the reason John keeps a copy open "for five or ten, who knows".

  A roster that grew per epic would make the second epic more expensive than the
  first and would put three more agents on the machine every time somebody
  approved something. It would also break the boundary the next rule draws: if
  agents accumulate on a copy, discarding the copy stops meaning "that work is
  over".

  ## Red on purpose

  There are no agents on a copy to be the same ones. See criterion 3087.
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

  defp agent_ids(html) do
    ~r/data-test="agent-chip"[^>]*data-agent-id="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(&List.last/1)
    |> Enum.sort()
  end

  defp copies_page(context) do
    {:ok, _live, html} =
      live(context.conn, ~p"/app/projects/#{context.project.id}/working-copies")

    html
  end

  spex "A working copy comes up with its three agents" do
    scenario "The same three take the next epic" do
      given_ :synced_context_component

      given_ "a working copy whose three agents have finished an epic", context do
        context = EpicHelpers.dispatch_one(context, "The first epic", stories: 1)
        before = agent_ids(copies_page(context))

        assert length(before) == 3,
               "the premise needs a copy with its three agents on it, and it came up " <>
                 "with #{length(before)}. Criterion 3087 is the one that fails first."

        {:ok, Map.put(context, :before, before)}
      end

      when_ "I approve a second epic onto that copy", context do
        context = EpicHelpers.dispatch_one(context, "The second epic", stories: 1)

        {:ok, Map.put(context, :after, agent_ids(copies_page(context)))}
      end

      then_ "the same three agents pick it up", context do
        assert context.after == context.before,
               "the copy's agents changed when it was given more work. The three are " <>
                 "the copy's, not the epic's — that is what makes a second epic cheaper " <>
                 "than the first."

        {:ok, context}
      end

      then_ "and no new agents are started for it", context do
        assert length(context.after) == 3,
               "there are #{length(context.after)} agents on one copy. A roster that " <>
                 "grows per epic puts three more processes on the machine every time " <>
                 "somebody approves something, and discarding the copy stops meaning " <>
                 "that the work on it is over."

        {:ok, context}
      end
    end
  end
end
