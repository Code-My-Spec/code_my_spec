defmodule CodeMySpecSpex.Story1057.Criterion3312Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 3312 — A fault the main agent cannot act on is raised.

  Rule: what you cannot fix, you report — and you stop trying to fix it.

  The whole value of story 1057 sitting under story 1056. Once the main agent
  can restart, its reflex on any fault is a restart; this says that when the
  machinery is what is broken, the reflex is wrong and something else has to
  happen instead.

  "And it does not restart agents repeatedly in the hope of clearing it" is the
  half with teeth. Restarting an agent whose harness holds a dead MCP client
  brings it back into the same dead client — the fault is underneath it — so
  every attempt costs a turn and changes nothing, and the main agent has no way
  to learn that from the outcome, because the outcome looks the same as an agent
  that is simply slow to recover.

  ## Distinct from 1056's 3292 and 3308

  Those are about the main agent noticing, after the fact, that restarting is
  not working — a count of failed remedies. This is about not starting: the
  machinery being faulty is known *before* the first restart, from the report,
  and acting on it anyway is a mistake the report already had the information to
  prevent.

  So the scenario asserts against attempt number one, not number four.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckMachinery
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A machinery fault is reported instead of restarted around" do
    scenario "the harness is holding a dead tool client" do
      given_ "a checkout whose machine can run nothing, and agents on it", context do
        reply = join_working_copy(context, "/tmp/spex-3312", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        {:ok, _integration} = Fixtures.connect_provider(scope, :zai)

        agents =
          for role <- ["coding", "qa"] do
            Fixtures.running_agent(scope, role: role, working_copy: "/tmp/spex-3312")
          end

        # Underneath every agent on this copy, and not clearable by restarting
        # any of them: they come back into the same dead client.
        Fixtures.record_machine_tools(scope, [])

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agents, agents)}
      end

      when_ "the main agent finds it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, report, _frame} = CheckMachinery.execute(%{}, frame)

        refute report.isError, inspect(report)

        {:ok, Map.put(context, :report, response_text(report))}
      end

      then_ "it raises the fault", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, issues, _frame} = ListIssues.execute(%{}, frame)

        assert response_text(issues) =~ ~r/tool/i,
               """
               A machinery fault nothing the main agent can do would clear was
               found and not written down.

               Finding it and saying nothing is the same outcome as not looking:
               the agents stay broken, and the only party that noticed has
               already moved on.

               report:
               #{context.report}

               issues:
               #{response_text(issues)}
               """

        {:ok, context}
      end

      then_ "and restarting an agent for it is refused on the first attempt",
            context do
        [agent | _] = context.agents
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          RestartAgent.execute(
            %{agent_id: agent.id, reason: "its machine reports no tools"},
            frame
          )

        assert response.isError,
               """
               The main agent restarted an agent for a fault that is underneath
               it.

               It comes back into the same dead client, so the attempt costs a
               turn and changes nothing — and the main agent cannot learn that
               from the outcome, because an agent that came back broken looks
               exactly like one that is slow to recover.

               This is attempt number one, deliberately. Criteria 3292 and 3308
               are about noticing after several that restarting is not working;
               this is about not starting, because the report already carried
               the information that would have prevented it.

               reply:
               #{response_text(response)}
               """

        {:ok, context}
      end
    end
  end
end
