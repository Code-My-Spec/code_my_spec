defmodule CodeMySpecSpex.Story1056.Criterion3290Spex do
  @moduledoc """
  Story 1056 — The main agent starts, stops and restarts its agents.
  Criterion 3290 — The main agent acts on what it sees.

  The first spex on this story, so it chooses the surface the rest inherit.

  ## Why a MainAgent tool rather than the existing `stop_agent` / `start_agent`

  Those exist and they work. What they do not carry is the half this story is
  about: a restart with a reason attached, judged afterwards against what it was
  meant to fix (3291), refused when it has already been tried and changed
  nothing (3292), and visible as the point an agent stopped working when it made
  things worse (3293).

  None of that belongs on `Agents`. That context owns one agent's lifecycle —
  start it, stop it, message it — and it is deliberately without an opinion
  about whether starting is a good idea. The opinion is the main agent's, and
  `CodeMySpec.MainAgent` is where its opinions live. So
  `McpServers.MainAgent.Tools.RestartAgent`, taking the agent and the reason.

  A stop-then-start pair was the other option and is wrong for a reason already
  written into `Agents.restart_agent/2`: starting afresh inserts a new row, and
  a conversation keys on the agent id, so the replacement comes back with an
  empty transcript. A restart that costs the agent its memory is not a restart.

  ## The fault is the agent's own, deliberately

  This first said "its machine reports no tools", which is a *machinery* fault —
  and story 1057's criterion 3312 says the main agent must refuse to restart for
  one of those, because the agent comes back into the same dead client. The two
  criteria contradicted each other until this one used a fault a restart can
  actually reach.

  So: an agent holding a task, silent for hours, on a machine that is answering
  normally. That is 1057's criterion 3311 shape — a fault nothing else shares —
  and it is the only kind restarting is the right remedy for.

  ## What this criterion claims

  Only that the act is available to the main agent and takes effect. The reason,
  the repeat-suppression and the escalation are 3291, 3292 and 3308.

  The second half — "the main agent did not need a person to do it" — is
  structural: the tool is called on the main agent's own scope with no approval
  step in between. There is nothing else to assert, and a scenario that invented
  one would be testing an approval gate the criterion says must not exist.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Seeing a broken agent is enough to do something about it" do
    scenario "an agent cannot reach its tools" do
      given_ "an agent the main agent can see is not working", context do
        reply = join_working_copy(context, "/tmp/spex-3290", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        # The provider these agents run on — `running_agent/2` defaults to zai.
        # `Agents.restart_agent/2`
        # resolves one before it attempts anything — deliberately, so a restart
        # fails here rather than minutes later on the agent's first model call.
        {:ok, _integration} = CodeMySpecSpex.Fixtures.connect_provider(scope, :zai)

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3290"
          )

        # The machine is answering normally, so whatever is wrong is this
        # agent's own — the only kind a restart reaches.
        CodeMySpecSpex.Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])

        {_agent, _task} =
          CodeMySpecSpex.Fixtures.agent_task_fixture(scope, agent,
            requirement_name: "implementation_file",
            started_at: DateTime.add(DateTime.utc_now(), -3 * 60 * 60, :second)
          )

        :ok = CodeMySpecSpex.Fixtures.agent_said(scope, agent, "starting on it")
        :ok = CodeMySpecSpex.Fixtures.age_agent_messages(scope, agent, 3 * 60 * 60)

        frame = %Frame{assigns: %{current_scope: scope}}
        {:reply, view, _frame} = ListAgentWork.execute(%{}, frame)

        assert response_text(view) =~ ~r/last said/i,
               "the premise is an agent the main agent can see has stopped:\n" <>
                 response_text(view)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "it restarts that agent", context do
        # On the main agent's own scope, with nothing in between. "Did not need
        # a person to do it" is this call working at all.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          RestartAgent.execute(
            %{
              agent_id: context.agent.id,
              reason: "it has held a task for three hours in silence"
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the agent is restarted", context do
        refute context.response.isError,
               """
               The main agent could not restart an agent it can plainly see is
               broken.

               Watching without being able to act is the state this story
               exists to end: over one session the only things that changed
               anything were restarts, and every one of them was a person
               typing.

               reply:
               #{response_text(context.response)}
               """

        assert response_text(context.response) =~ context.agent.id,
               """
               The reply does not say which agent was restarted.

               One agent and only one is the whole care of criterion 3306, and a
               reply that does not name it cannot be checked against that.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end
    end
  end
end
