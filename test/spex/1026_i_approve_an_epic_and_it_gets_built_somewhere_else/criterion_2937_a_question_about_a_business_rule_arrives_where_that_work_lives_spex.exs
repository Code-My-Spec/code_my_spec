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

        # The index lists threads rather than what is in them, so finding the
        # question means opening one — which is also what a person does.
        {:ok, _live, index} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        threads =
          ~r"/agent-conversation/([0-9a-f-]{36})"
          |> Regex.scan(index)
          |> Enum.map(fn [_, id] -> id end)
          |> Enum.uniq()

        holding =
          Enum.filter(threads, fn id ->
            {:ok, _live, html} =
              live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation/#{id}")

            html =~ "Which rate applies to overseas orders?"
          end)

        {:ok,
         context
         |> Map.put(:index, index)
         |> Map.put(:threads, threads)
         |> Map.put(:holding, holding)}
      end

      then_ "the question is on a conversation of its own", context do
        assert context.holding != [],
               "the dispatched agent's question reached no conversation at all, so it is " <>
                 "waiting on an answer nobody can see it needs"

        {:ok, context}
      end

      then_ "and it is not in the conversation I have with the main agent", context do
        main =
          ~r/data-test="main-agent"[^>]*href="[^"]*\/agent-conversation\/([0-9a-f-]{36})"/s
          |> Regex.run(context.index)
          |> main_agent_id_match()

        refute main && main in context.holding,
               "a dispatched agent's question landed in the project conversation. That " <>
                 "thread is where the user and the main agent talk about the project, and " <>
                 "six agents dropping rule questions into it makes it unreadable."

        {:ok, context}
      end
    end
  end

  defp main_agent_id_match([_, id]), do: id
  defp main_agent_id_match(nil), do: nil
end
