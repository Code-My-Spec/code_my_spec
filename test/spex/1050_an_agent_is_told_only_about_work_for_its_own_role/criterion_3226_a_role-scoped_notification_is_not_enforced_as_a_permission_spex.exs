defmodule CodeMySpecSpex.Story1050.Criterion3226Spex do
  @moduledoc """
  Story 1050 — An agent is told only about work for its own role.
  Criterion 3226 — A role-scoped notification is not enforced as a permission.

  3202 and 3203 each show one operation staying open. This says the rule in
  general, and the second Then says something the other two cannot: not just
  that the read works, but that a permission check is not the *mechanism* by
  which notifications are scoped.

  The difference is real and it is invisible from the first Then alone. An
  implementation can scope notifications by asking "may this agent act on
  this?" and suppressing the message when the answer is no. Every routing
  criterion on this story passes. Then somebody widens a permission for an
  unrelated reason and the routing changes with it — or narrows one, and an
  agent silently stops being told about its own work.

  Story 1038's criterion 3020 already establishes that roles *do* scope what an
  agent may call — a QA agent cannot delete the story it is testing. So this is
  not "there are no permissions". It is that the notification filter is a
  separate thing, and reusing the permission answer to build it couples two
  rules that change for different reasons.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The role filter scopes what an agent is told, never what it may do" do
    scenario "A role-scoped notification is not enforced as a permission" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a coding agent never told about a QA finding", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        Fixtures.running_agent(context.scope, role: "qa")
        context = context |> start_session() |> put_to_work()

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "the ledger rounds the wrong way on refunds",
              description: "found while testing the refund path",
              severity: "medium",
              scope: "qa"
            },
            frame(context)
          )

        refute filed.isError, "the premise is a finding that exists"

        refute_told_anything(
          context,
          coding.id,
          heard_count(context, coding.id),
          "the premise is an agent that was never told"
        )

        {:ok, Map.put(context, :coding, coding.id)}
      end

      when_ "it tries to read or act on that finding", context do
        {:reply, listed, _frame} = ListIssues.execute(%{}, frame(context))

        read = read_issue(issue_id_in(response_text(listed)), listed, context)

        {:ok,
         context
         |> Map.put(:listed, listed)
         |> Map.put(:read, read)
         |> Map.put(:text, response_text(listed) <> "\n" <> response_text(read))}
      end

      then_ "nothing refuses it on the grounds of its role", context do
        refute context.listed.isError,
               "the coding agent cannot list findings at all: #{response_text(context.listed)}"

        refute context.read.isError,
               "the coding agent cannot read a finding: #{response_text(context.read)}"

        assert context.text =~ "the ledger rounds the wrong way on refunds",
               """
               The finding is not reachable by an agent of another role.

               Story 1038's 3020 already establishes that roles scope what an
               agent may *call* — a QA agent cannot delete the story it is
               testing. This is not "there are no permissions"; it is that
               reading a finding is not one of the things a role withholds.

               #{context.text}
               """

        {:ok, context}
      end

      then_ "and the refusal it would have received is not the mechanism used to scope notifications",
            context do
        refute context.text =~ ~r/(not your role|role does not|wrong role|only the qa)/i,
               """
               The read came back carrying a role refusal, which means the
               permission answer is in this path — and a notification filter
               built on it is coupled to it.

               That coupling is invisible until somebody widens a permission
               for an unrelated reason and the routing changes with it, or
               narrows one and an agent silently stops being told about its own
               work. Two rules that change for different reasons should not
               share an answer.

               #{context.text}
               """

        {:ok, context}
      end
    end
  end

  # The listing named no issue, so there is nothing further to open — the
  # listing itself is then the whole of what the agent could reach, and the
  # assertions below read it as such.
  defp read_issue(nil, listed, _context), do: listed

  defp read_issue(id, _listed, context) do
    {:reply, reply, _frame} = GetIssue.execute(%{issue_id: id}, frame(context))
    reply
  end

  defp issue_id_in(text) do
    ~r/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/
    |> Regex.run(text)
    |> first_capture()
  end

  defp first_capture([_whole, id]), do: id
  defp first_capture(_no_match), do: nil
end
