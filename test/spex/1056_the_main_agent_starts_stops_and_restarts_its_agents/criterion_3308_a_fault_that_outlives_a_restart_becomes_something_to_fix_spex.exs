defmodule CodeMySpecSpex.Story1056.Criterion3308Spex do
  @moduledoc """
  Story 1056 — The main agent starts, stops and restarts its agents.
  Criterion 3308 — A fault that outlives a restart becomes something to fix.

  Rule: a fault a restart does not clear is a bug, not weather.

  The criterion's own second clause is the load-bearing one: "treated as a bug
  to be fixed rather than a state to be managed". Managing it is the comfortable
  outcome and the expensive one — the main agent restarts, the fault persists,
  it restarts again, and the project acquires a permanent minor outage that
  nobody ever writes down because something is always about to fix it.

  ## The difference from 3292

  3292 is about the main agent's own behaviour after several failed attempts:
  stop trying. This fires after **one** — the first restart that changes nothing
  is already evidence that restarting is the wrong remedy, and waiting for the
  third to say so costs two more turns and the delay.

  They also fail in opposite directions. 3292 fails by trying again; this fails
  by staying quiet. An implementation could satisfy either and miss the other:
  a main agent that refuses the second restart and files nothing passes 3292's
  first half, and one that files an issue and keeps restarting passes this one.

  ## Loudly, and once

  An issue rather than a log line, because a log is not somewhere anybody looks
  at a particular project, and this is precisely the class of fault that was
  invisible for four hours. `create_issue`'s own documentation says friction
  with the framework is a first-class issue rather than something to work
  around — a fault surviving its remedy is exactly that.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @reason "it stopped answering after its last turn"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The first restart that changes nothing is reported" do
    scenario "an agent is restarted and the same fault is still there" do
      given_ "an agent that has been restarted once for a fault", context do
        reply = join_working_copy(context, "/tmp/spex-3308", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        # The provider these agents run on — `running_agent/2` defaults to zai.
        # `Agents.restart_agent/2`
        # resolves one before it attempts anything — deliberately, so a restart
        # fails here rather than minutes later on the agent's first model call.
        {:ok, _integration} = CodeMySpecSpex.Fixtures.connect_provider(scope, :zai)

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3308")

        # A healthy machine: a machinery fault is refused outright (story 1057,
        # criterion 3312) and never reaches the "restarted and it did not help"
        # state this criterion is about.
        Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])
        :ok = Fixtures.agent_said(scope, agent, "starting on it")
        :ok = Fixtures.age_agent_messages(scope, agent, 3 * 60 * 60)

        frame = %Frame{assigns: %{current_scope: scope}}

        {:reply, restarted, _frame} =
          RestartAgent.execute(%{agent_id: agent.id, reason: @reason}, frame)

        refute restarted.isError, inspect(restarted)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent sees the restart changed nothing", context do
        # Still silent. The restart ran and the fault is exactly where it was.

        # Seeing is `list_agent_work` — the criterion says "when the main agent
        # sees", not "when it tries again", and the difference is the whole
        # point. Waiting for the next attempt is what turns a fault into a state
        # to be managed: nothing else is looking, so the only thing that would
        # report it is the thing the report exists to prevent.
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, _view, _frame} = ListAgentWork.execute(%{}, frame)

        {:reply, issues, _frame} = ListIssues.execute(%{}, frame)

        {:ok, Map.put(context, :issues, response_text(issues))}
      end

      then_ "the fault is raised as a bug to be fixed", context do
        assert context.issues =~ @reason,
               """
               A fault survived its remedy and nothing was written down.

               This is the comfortable failure and the expensive one. The main
               agent restarts, the fault persists, it restarts again, and the
               project acquires a permanent minor outage nobody records because
               something is always about to fix it.

               One restart is already enough evidence that restarting is the
               wrong remedy — waiting for the third to say so, which is what
               3292 does, costs two more turns and the delay. The two criteria
               also fail in opposite directions: 3292 fails by trying again,
               this one by staying quiet, and an implementation can satisfy
               either while missing the other.

               An issue rather than a log line, because a log is not somewhere
               anybody looks at a particular project — and this is exactly the
               class of fault that went unseen for four hours.

               issues:
               #{context.issues}
               """

        {:ok, context}
      end
    end
  end
end
