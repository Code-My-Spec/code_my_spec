defmodule CodeMySpecSpex.Story1059.Criterion3333Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 3333 — A digest that cannot be assembled is not delivered as an
  empty one.

  Rule: "I could not look" and "I looked and all is well" are opposite answers.

  The worst failure available on this story, because it fails in the reassuring
  direction. A digest that cannot be built and is delivered empty says exactly
  what a healthy fleet says, seventy-two times a day, for as long as whatever
  broke stays broken — and the main agent has no way to tell, because an empty
  list is what a quiet project looks like.

  It is also the failure a check-in loop is most likely to have. The digest
  reads several things; any one of them being unavailable produces a shorter
  list rather than an error, because that is what "no rows" means everywhere
  else in this system.

  ## The shape of the scenario

  Agents exist and are doing things, so a working digest would not be empty.
  What is unavailable is a thing the digest reads — the analyzer ledger — and
  the criterion is that the main agent hears about the failure rather than
  inheriting its silence.

  Both halves are asserted. Nothing that reads as all-quiet, *and* the failure
  raised: a cadence that silently skipped a tick would satisfy the first half
  and leave the same hole, with one fewer clue.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A check-in that could not look says so" do
    scenario "something the digest reads is unavailable" do
      given_ "agents at work and a digest source that will not answer", context do
        reply = join_working_copy(context, "/tmp/spex-3333", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-3333")
        coding = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3333")

        {_agent, _task} =
          Fixtures.agent_task_fixture(scope, coding, requirement_name: "implementation_file")

        # A working digest would have plenty to say about this project. What is
        # broken is a thing it reads, not the project.
        :ok = Fixtures.break_digest_source(scope)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:main, main)
         |> Map.put(:coding, coding)}
      end

      when_ "the cadence comes round", context do
        :ok = Fixtures.cadence_tick(context.scope)

        {:ok, context}
      end

      then_ "the main agent is not handed an all-quiet", context do
        {:ok, _live, html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, context.main))

        refute html =~ ~r/nothing to report|all quiet|everything is fine/i,
               """
               A digest that could not be built was delivered as though it had
               been, and found nothing.

               This is the worst failure on this story because it fails in the
               reassuring direction: it says exactly what a healthy fleet says,
               seventy-two times a day, for as long as whatever broke stays
               broken — and nothing can tell the difference, because an empty
               list is what a quiet project looks like.

               transcript:
               #{html}
               """

        {:ok, context}
      end

      then_ "and the failure to assemble it is raised", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, issues, _frame} = ListIssues.execute(%{}, frame)

        assert response_text(issues) =~ ~r/digest|check-?in/i,
               """
               The check-in could not look and nobody was told.

               A cadence that silently skipped the tick satisfies the first half
               of this criterion and leaves the same hole with one fewer clue:
               nothing said all-quiet, and nothing said anything at all, which
               from the outside is the same thing.

               issues:
               #{response_text(issues)}
               """

        {:ok, context}
      end
    end
  end
end
