defmodule CodeMySpecSpex.Story1054.Criterion3300Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3300 — A clean working copy shows no problems against its agent.

  Rule: a clean copy is a finding, and it is reported as one.

  The counterweight to 3299, and the same shape as 3298 is to 3272: one
  criterion says a condition must be visible, this one says its absence must be
  visible too, and for the same reason. "No problems listed" and "problems not
  checked" render identically as nothing, and they mean opposite things — the
  first says the agent's copy is fine and look elsewhere, the second says you
  still have to look.

  It also guards 3299 from a cheap pass. A view that printed every problem on
  the project against every agent would satisfy 3299 completely; it fails here,
  because this agent's copy has none and the other one's problems would show up
  against it.

  That is why the scenario runs two checkouts. With one, "shows no problems"
  proves nothing beyond the absence of problems anywhere — and the criterion
  is about attribution, not about emptiness.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent on a clean copy is told its copy is clean" do
    scenario "one checkout carries problems and another does not" do
      given_ "an agent on a clean checkout and another on one with problems",
             context do
        clean_reply = join_working_copy(context, "/tmp/spex-3300-clean", "the clean checkout")
        clean_scope = %{context.scope | active_working_copy_id: clean_reply.working_copy_id}

        clean_agent =
          CodeMySpecSpex.Fixtures.running_agent(clean_scope,
            role: "coding",
            working_copy: "/tmp/spex-3300-clean"
          )

        dirty_reply = join_working_copy(context, "/tmp/spex-3300-dirty", "the dirty checkout")
        dirty_scope = %{context.scope | active_working_copy_id: dirty_reply.working_copy_id}

        dirty_agent =
          CodeMySpecSpex.Fixtures.running_agent(dirty_scope,
            role: "qa",
            working_copy: "/tmp/spex-3300-dirty"
          )

        # On the other copy, and only there. A view that printed every problem
        # on the project against every agent would satisfy 3299 and fail here.
        {:ok, _problems} =
          CodeMySpecSpex.Fixtures.record_problem(dirty_scope, "credo", %{
            message: "cyclomatic complexity is too high",
            file_path: "lib/my_app/dispatch.ex"
          })

        {:ok,
         context
         |> Map.put(:scope, clean_scope)
         |> Map.put(:clean_agent, clean_agent)
         |> Map.put(:dirty_agent, dirty_agent)}
      end

      when_ "the main agent looks at the agent on the clean copy", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, entry_for(response_text(response), context.clean_agent.id))}
      end

      then_ "its copy is reported clean rather than left blank", context do
        refute context.view =~ "cyclomatic complexity is too high",
               """
               Another checkout's problem is shown against this agent.

               A view that prints every problem on the project against every
               agent satisfies criterion 3299 completely and is useless: the
               main agent cannot tell whose copy is broken, which is the only
               thing it wanted to know.

               entry:
               #{context.view}
               """

        assert context.view =~ ~r/no problems|clean/i,
               """
               The clean copy is reported as nothing rather than as clean.

               "No problems listed" and "problems not checked" render
               identically and mean opposite things — the first says look
               elsewhere, the second says you still have to look here. An
               absence that cannot be told from an omission is not information.

               entry:
               #{context.view}
               """

        {:ok, context}
      end
    end
  end

  # The listing covers both agents, and this criterion is about one of them.
  # Asserting against the whole reply would let the other agent's problems
  # satisfy a refutation about this one, which is the confusion the criterion is
  # about.
  defp entry_for(view, agent_id) do
    view
    |> String.split(~r/\n(?=\s*Agent:)/)
    |> Enum.find(view, &String.contains?(&1, agent_id))
  end
end
