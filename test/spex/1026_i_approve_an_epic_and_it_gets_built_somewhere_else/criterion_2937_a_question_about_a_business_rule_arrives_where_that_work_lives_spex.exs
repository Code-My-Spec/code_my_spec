defmodule CodeMySpecSpex.Story964.Criterion2937Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2937 — A question about a business rule arrives where that work
  lives.

  Rule: A dispatched agent's questions come back on their own thread, not in the
  project conversation.

  John: *"these other agents can come back and ask us questions about business
  rules and stuff and that'll all go into those other sub conversations."*

  The main conversation stays at the level of the project. An agent three
  layers down asking which VAT rate applies is a real question and it belongs
  beside the work that raised it — dropped into the project thread it buries the
  conversation the main agent and the user are actually having, and six agents
  doing it makes that thread unreadable.

  Story 962 already made a conversation belong to an agent rather than a
  checkout, which is what makes this possible: the dispatched agent has a thread
  of its own by construction.

  ## Read through two pages, not a thread index

  This was written against `/agent-conversation/<id>` and an index that listed
  threads. Neither exists: the router has one agent-conversation route reached
  by `?conversation=`, and the panel that replaced the index lists *agents* —
  a dispatched agent's thread is keyed to the epic and has no agent row, so it
  is not in that list and cannot be found by scraping the page for links.

  Scraping produced an empty list of threads and the criterion failed saying the
  question reached no conversation at all, which was a statement about the
  selector rather than about the product.

  So both pages are named rather than discovered: the dispatched thread through
  the same `epic:<id>` key the product writes under, and the project
  conversation through the bare URL, which is the one the user and the main
  agent talk in. That is the pair the criterion is actually about.
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

  spex "A dispatched agent's questions come back on their own thread, not in the project conversation" do
    scenario "A question about a business rule arrives where that work lives" do
      given_ :synced_context_component

      given_ "an agent building an epic on its own working copy", context do
        context = EpicHelpers.dispatch_one(context, "Work that raises questions", stories: 1)

        {:ok, context}
      end

      when_ "it asks me about a business rule", context do
        EpicHelpers.agent_asks(context, "Which rate applies to overseas orders?")

        # Both threads, read as a person reads them. The bare URL is the
        # conversation the user and the main agent are having; the other is the
        # dispatched agent's own.
        {:ok, _live, project_thread} =
          live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

        {:ok, _live, dispatched_thread} =
          live(context.conn, EpicHelpers.dispatched_thread_path(context))

        {:ok,
         context
         |> Map.put(:project_thread, project_thread)
         |> Map.put(:dispatched_thread, dispatched_thread)}
      end

      then_ "the question is on a conversation of its own", context do
        assert context.dispatched_thread =~ "Which rate applies to overseas orders?",
               "the dispatched agent's question reached no conversation at all, so it is " <>
                 "waiting on an answer nobody can see it needs"

        {:ok, context}
      end

      then_ "and it is not in the conversation I have with the main agent", context do
        refute context.project_thread =~ "Which rate applies to overseas orders?",
               "a dispatched agent's question landed in the project conversation. That " <>
                 "thread is where the user and the main agent talk about the project, and " <>
                 "six agents dropping rule questions into it makes it unreadable."

        {:ok, context}
      end
    end
  end
end
