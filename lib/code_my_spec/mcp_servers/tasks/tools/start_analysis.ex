defmodule CodeMySpec.McpServers.Tasks.Tools.StartAnalysis do
  @moduledoc """
  Start an analyzer run and return immediately.

  Sources: `spex`, `exunit`, `credo`, `compiler`. Returns as soon as the run is
  opened — it does not wait, and you should not wait for it.

  An agent running inside our own BEAM is sent the result as a message when the
  run lands, so the thing to do after calling this is stop. A Claude Code
  session collects it on its next tool call instead.
  """

  # Kept short deliberately: `Anubis.Server.Component` advertises the moduledoc
  # as this tool's `description`, so every word is sent to every agent at
  # connect and `SpineTest` caps that payload at 20 KB.
  #
  # Why this exists: the agent had no way to begin a run. `FixBddSpecs` handed
  # it `curl -X POST localhost:4004/api/harnesses/<id>/analysis/run`, and the
  # internal agent then held that command open on a sweep that takes several
  # minutes — the timeout John reported.
  #
  # A sync usually covers it: `sync_project` sends `:rescan`, the harness
  # re-reads the tree, and changed files enqueue analysis. That is the ordinary
  # path and it stays the ordinary path. This is for the case the external
  # directive already named — the wait returns straight away and nothing is
  # running, so there is nothing to wait for.
  #
  # `await_run/4` is the only entry point and it blocks by construction: the run
  # is opened here, executed on the machine with the disk, and closed when the
  # result comes back, so the caller waits on a broadcast rather than a return
  # value. Run in a task, that becomes a start — the completion still flows
  # through `Reconciler.reconcile/4`, which is where `Analysis.AgentReport`
  # tells the agent.

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Analysis

  @sources ~w(spex exunit credo compiler)

  schema do
    field :source, :string, required: true, doc: "spex | exunit | credo | compiler"
  end

  @impl true
  def execute(%{source: source}, frame) when source in @sources do
    scope = frame.assigns[:current_scope]
    agent_id = frame.assigns[:agent_id]

    # Captured here, not read back inside the task: `Logger.metadata` and
    # `frame.assigns` are both tied to this process, and the task below is
    # unlinked and separate — by the time it calls `start_run`, neither would
    # still say who asked.
    requested_by = %{kind: "mcp_tool", tool: "start_analysis", agent_id: agent_id}

    # Unlinked on purpose. The caller is answered as soon as the run is opened,
    # and a tool call that ends must not take a sweep with it.
    Task.Supervisor.start_child(CodeMySpec.TaskSupervisor, fn ->
      Analysis.await_run(scope, source, [], requested_by: requested_by)
    end)

    {:reply, Response.tool() |> Response.text(started(source, frame.assigns[:agent_id])), frame}
  end

  def execute(%{source: source}, frame) do
    {:reply,
     Response.tool()
     |> Response.error(
       "#{inspect(source)} is not an analyzer. Use one of: #{Enum.join(@sources, ", ")}."
     ), frame}
  end

  # "Requested", not "Started", and the difference is not pedantry.
  #
  # Analyzer concurrency is one run machine-wide. A request made while another
  # copy is running queues behind it, and nothing on this side knows which
  # happened — the harness does, and logs "an analyzer run is waiting for a
  # machine-wide slot: 1 already running (limit 1), waiting up to 1800000ms".
  # Saying "Started" promises something this tool cannot check.
  #
  # The cost of the promise is an agent that holds its task and waits forever.
  # `Work.runnable_state?/1` skips an agent with an open task, so once it is
  # waiting on a result that never lands, no wake path in the system can reach
  # it — only a human message. Measured on the math project 2026-09-22 three
  # times in one session: 22, 25 and 26 minutes, each ended by hand, each agent
  # doing exactly what this text told it to do.
  #
  # So the text now says what is true (a request was recorded), what silence
  # means (it may be queued), and what to do about it (dispose of the task
  # rather than hold it open). `evaluate_task` answers "analysis pending" for a
  # run that has not landed, which is a clean turn end rather than a hang.
  defp started(source, agent_id) when is_binary(agent_id) do
    """
    Requested #{source}. A run usually takes several minutes.

    Do not wait for it and do not poll — the result is delivered to you as a
    message when it lands. Stop when you have nothing else to do.

    If it has not landed by your next turn, it may be queued: analyzer runs are
    one-at-a-time across this whole machine, so another checkout's run can be
    ahead of yours. That is ordinary and not a fault of yours.

    Do not hold a task open waiting for it. Close the loop with `evaluate_task`,
    which answers "analysis pending" while no fresh run exists — an agent
    holding an open task cannot be offered another turn, so waiting with one
    held is how a turn becomes an indefinite wait.
    """
  end

  defp started(source, _agent_id) do
    """
    Started #{source}. It runs for several minutes.

    The digest reaches you on your next tool call once it lands. To block until
    it finishes instead, `POST localhost:4004/api/harnesses/<working_copy_id>/analysis/wait`.
    """
  end
end
