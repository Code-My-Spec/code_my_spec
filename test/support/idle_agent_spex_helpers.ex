defmodule CodeMySpecSpex.IdleAgentHelpers do
  @moduledoc """
  Story 1047's shared premise: agents on a working copy, a graph that holds work
  for some roles and not others, and a record of what each agent was actually
  told.

  Every criterion here is a claim about a *message* — that one arrived, that
  none did, that exactly one did. So the two things that have to be real are
  the graph the decision is made from and the transcript the agent reads. Both
  are: the graph is populated by calling `get_next_requirement` the way an
  agent does, and what an agent heard is read from the rows
  `Chat.Runner.to_provider_message/1` actually hands the model.

  That last point is the one with history. These rows used to be read at role
  `:orchestrator`, which the runner dropped from every model's context — so the
  assertions proved a person watching could see something and never that the
  agent had been told it. `Fixtures.messages_to_agent/2` reads `:operator` for
  that reason, and everything here goes through it.

  ## Counting, not matching

  "It is sent nothing" is the assertion half this story's criteria turn on, and
  it is only meaningful against a before. An agent that was already holding
  four messages and is holding four afterwards was sent nothing; asserting an
  empty list would fail on a premise that legitimately said something earlier.
  """

  import ExUnit.Assertions

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Stories.Tools.SetWorkingCopyLoop
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias Phoenix.ConnTest

  @doc """
  Put this working copy to work and populate the graph the menu counts from.

  Both halves are load-bearing. Without the loop the copy is switched off and
  every agent on it is correctly sent nothing, which passes four of these
  criteria for a reason that has nothing to do with them. Without a
  `get_next_requirement` the graph has never been computed, so every role reads
  zero and every wake is silent.

  Takes a copy id for the scenarios that staff more than one.
  `wake_project_roles/2` only wakes agents whose own row says `continuous`, and
  the loop is set per copy — so a scenario with two checkouts that switches on
  one of them has silenced the other by construction, and its "and the other
  agent was told nothing" then holds for the wrong reason.
  """
  @spec put_to_work(map(), Ecto.UUID.t() | nil) :: map()
  def put_to_work(context, copy_id \\ nil) do
    frame = frame(context)

    # Switch first, then compute, and it has to be this way round even though
    # the switch-on wake renders against whatever the graph already holds.
    # `GetNextRequirement` syncs the working copy on its way to the graph, and
    # the sync clears problems whose file is not on disk — which is every
    # problem `Fixtures.record_problem/3` writes, since its path is a name
    # rather than a file. Computing first swept them before the menu could
    # count them, and criteria 3183 and 3196 went silent for it.
    {:reply, _response, _frame} =
      SetWorkingCopyLoop.execute(
        %{working_copy_id: copy_id || context.scope.active_working_copy_id, working: true},
        frame
      )

    {:reply, _next, _frame} = GetNextRequirement.execute(%{}, frame)

    context
  end

  @doc """
  Claim a task the way an agent we run claims one — owned by the agent.

  `:context_spec_task_started` is the wrong premise for a criterion about what
  an *agent* holds. It posts `session-start` and passes a `session_id`, so the
  task lands on a `Session`, and `TaskOwner` is explicit that ownership is the
  list a task is stored in rather than a field on it. The agent then holds
  nothing, its menu counts zero open tasks, and it is correctly told to
  `get_next_requirement` — which is the very advice the criterion exists to
  rule out, arrived at honestly.

  `StartTask` reads `frame.assigns[:agent_id]` for exactly this, and the
  moduledoc on `TaskOwner` says why it has to: an agent we run fires no hooks,
  so nothing injects a session id and `register_session` is not a tool it
  carries.
  """
  @spec start_agent_task(map(), String.t(), map()) :: map()
  def start_agent_task(context, agent_id, attrs) do
    frame = %Frame{assigns: %{current_scope: context.scope, agent_id: agent_id}}

    {:reply, _response, _frame} = StartTask.execute(attrs, frame)

    context
  end

  @doc """
  A session for this copy, with no task started on it.

  Half this story's criteria are about an agent with *nothing* to do, so the
  `*_task_started` shared givens are the wrong premise for them: they open a
  task, and an open task is work. What is still needed is a session — the stop
  hook is addressed to one — so this drives the same `session-start` hook those
  givens do and stops there.

  Answers the context with `:session_id` on it.
  """
  @spec start_session(map()) :: map()
  def start_session(context) do
    session_id = "spex-#{System.unique_integer([:positive])}"

    # Dispatched explicitly rather than through `post/3`, because hooks live on
    # the local router and several of these criteria set `@endpoint` to the
    # cloud one for the pages they read. A helper that inherited whichever the
    # caller happened to declare would 404 in half of them.
    ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/api/hooks/session-start", %{
      "session_id" => session_id
    })
    |> ConnTest.json_response(200)

    Map.put(context, :session_id, session_id)
  end

  @doc "The frame a tool call from this scope is made in."
  @spec frame(map()) :: Frame.t()
  def frame(context), do: %Frame{assigns: %{current_scope: context.scope}}

  @doc "Everything this agent has been told, oldest first."
  @spec heard(map(), String.t()) :: [String.t()]
  def heard(context, agent_id), do: Fixtures.messages_to_agent(context.scope, agent_id)

  @doc "How many things this agent has been told."
  @spec heard_count(map(), String.t()) :: non_neg_integer()
  def heard_count(context, agent_id), do: length(heard(context, agent_id))

  @doc "The last thing this agent was told, or nil."
  @spec latest(map(), String.t()) :: String.t() | nil
  def latest(context, agent_id), do: context |> heard(agent_id) |> List.last()

  @doc """
  What was said to this agent since `before` messages had been said to it.

  The difference rather than the whole transcript, because every criterion here
  is about what *this* event caused and an agent's thread carries whatever put
  it in the state the premise describes.
  """
  @spec said_since(map(), String.t(), non_neg_integer()) :: [String.t()]
  def said_since(context, agent_id, before), do: context |> heard(agent_id) |> Enum.drop(before)

  @doc """
  Assert this agent was told nothing since `before`.

  Its own function because it is half this story and the failure message is the
  part that matters: a bare count comparison reports two numbers, and what the
  reader needs is the message that should not have been sent.
  """
  @spec refute_told_anything(map(), String.t(), non_neg_integer(), String.t()) :: :ok
  def refute_told_anything(context, agent_id, before, why) do
    said = said_since(context, agent_id, before)

    assert said == [],
           """
           #{why}

           #{length(said)} message(s) arrived:
           #{Enum.join(said, "\n---\n")}
           """

    :ok
  end

  @doc """
  The analyzer output a stop is judged against, all of it clean.

  Named here because six criteria need the same three files and the paths have
  to be expanded — a relative one resolves against the running process rather
  than the working copy, and the stop then reports findings from a file it
  never read.
  """
  @spec clean_analysis() :: map()
  def clean_analysis do
    %{
      "spex" => Path.expand("test/fixtures/validation/spex_green.jsonl"),
      "compile" => Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
      "exunit" => Path.expand("test/fixtures/validation/pipeline_clean_run/exunit.json")
    }
  end
end
