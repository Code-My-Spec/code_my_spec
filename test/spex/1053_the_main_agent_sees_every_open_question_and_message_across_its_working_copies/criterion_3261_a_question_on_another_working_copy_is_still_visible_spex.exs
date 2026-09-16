defmodule CodeMySpecSpex.Story1053.Criterion3261Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question and message across its
  working copies.
  Criterion 3261 — A question on another working copy is still visible.

  Rule: the main agent's view is the project's, not a checkout's.

  Criterion 3260 establishes that three agents' questions arrive in one place.
  This says the place is not a checkout. They are different claims and only this
  one fails against the obvious implementation — a listing scoped the way almost
  everything else in this codebase is scoped, to the working copy on the scope,
  which would pass 3260 and miss every question raised anywhere else.

  Worth pinning because per-copy scoping is right nearly everywhere else here
  and is applied deliberately: `Preloader.load/1` scopes files to one checkout,
  `GraphCache` keeps a row per copy, `Projection.vantage/1` resolves a reader to
  one tree. Each has a reason, and each reason is that a *verdict about the
  code* belongs to the tree it was computed from. A question is not a verdict
  about code. It is a person or an agent waiting, and it waits whatever
  checkout it was raised on.

  The failure mode is silence: an agent on a second worktree asks, the main
  agent's list does not show it, and nothing anywhere reports that a question
  went unseen. That is the shape story 1053 exists to close.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One project's questions, wherever they were raised" do
    scenario "two checkouts of one project each have an agent with a question" do
      given_ "an agent on each of two working copies, each with a question open",
             context do
        copies =
          for {root, label} <- [{"/tmp/spex-3261-a", "the first"}, {"/tmp/spex-3261-b", "the second"}] do
            reply = join_working_copy(context, root, label)
            scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

            agent =
              CodeMySpecSpex.Fixtures.running_agent(scope, role: "coding", working_copy: root)

            frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

            {:reply, response, _frame} =
              AskUserQuestion.execute(
                %{
                  title: "a question from #{label} checkout",
                  questions: [
                    %{
                      "question" => "What should #{label} checkout do?",
                      "options" => [%{"label" => "A"}, %{"label" => "B"}]
                    }
                  ]
                },
                frame
              )

            refute response.isError, inspect(response)

            %{label: label, scope: scope, agent: agent}
          end

        {:ok, Map.put(context, :copies, copies)}
      end

      when_ "the main agent looks at what is waiting, from one of them", context do
        # Deliberately asks as the *first* checkout. The main agent always has
        # some checkout on its scope — it runs somewhere — so "the project's
        # view" has to mean the view is not narrowed by wherever it happens to
        # be standing. Asking from a scope with no checkout at all would pass
        # against a per-copy implementation and prove nothing.
        [first | _] = context.copies

        frame = %Frame{assigns: %{current_scope: first.scope}}
        {:reply, response, _frame} = ListNotifications.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :listing, response_text(response))}
      end

      then_ "both checkouts' questions are listed", context do
        for %{label: label} <- context.copies do
          assert context.listing =~ "What should #{label} checkout do?",
                 """
                 The question raised on #{label} checkout is missing from the
                 main agent's list.

                 A listing scoped to the asking checkout satisfies criterion
                 3260 and fails here, which is why this criterion exists
                 separately. The main agent runs on one checkout and is
                 responsible for all of them, so a view narrowed to where it
                 happens to be standing leaves an agent waiting on a copy it
                 never looks at — and nothing reports that, because from the
                 main agent's side the list simply looks short.

                 listing:
                 #{context.listing}
                 """
        end

        {:ok, context}
      end
    end
  end
end
