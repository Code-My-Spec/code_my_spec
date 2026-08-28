defmodule CodeMySpec.Intake.Conversation do
  @moduledoc """
  One guided-intake conversation, as a process.

  The LiveView used to drive the flow: it decided whether a submission was a
  description or an answer, recorded the turn, called the model, and assigned
  the result. That put the conversation in the socket, and a socket is the one
  thing in this system guaranteed to go away — a reload, a dropped connection, a
  phone locking. Every bug in this feature has been a variation on that: the
  turns lost on reload, the call lost mid-flight, the re-ask that produced a
  different question each time because there was nothing to restore.

  So the conversation owns itself. `said/2` is the only way in: the process
  decides what the submission means from the plan's own status, records it, asks
  the model, writes the result, and tells whoever is watching. A LiveView
  subscribes and renders. It can come and go freely, and several can watch at
  once, because none of them is holding anything.

  ## Why a process and not a task

  A task per turn would survive a reload, which was the first fix. It would not
  serialise: two submissions racing produce two model calls and two answers for
  one question, and the row keeps whichever lands second. A process per
  conversation has a mailbox, so turns queue behind each other by construction.

  ## Lifetime

  Started on demand under `Intake.ConversationSupervisor` and registered by plan
  id, so `said/2` from any process reaches the same conversation. It stops after
  `@idle_timeout` with nothing to do — the state that matters is on the row, and
  a conversation nobody is having should not hold a process open. Coming back
  starts a fresh one that reads the row.
  """

  use GenServer, restart: :temporary

  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.Plan

  require Logger

  # Long enough to cover a visitor thinking about their answer, short enough
  # that an abandoned intake does not hold a process for the afternoon. The row
  # outlives it either way.
  @idle_timeout to_timeout(minute: 30)

  @doc """
  Tells this plan's conversation what the visitor said.

  Returns once the turn is recorded and the model call is under way — not once
  it has answered. The answer arrives by broadcast, to everyone watching.
  """
  @spec said(Plan.t(), String.t()) :: {:ok, Plan.t()} | {:error, term()}
  def said(%Plan{} = plan, text) do
    if process?() do
      plan
      |> ensure_started()
      |> GenServer.call({:said, text}, to_timeout(second: 10))
    else
      # Inline in test, where a process the sandbox does not own cannot see the
      # transaction — the `content_pull_async` convention. `ConversationTest`
      # exercises the real process with an explicit ownership grant, so the
      # thing this module exists for is still covered.
      case record_and_shape_inline(plan, text) do
        {:ok, _} = ok -> ok
        other -> other
      end
    end
  end

  defp process?, do: Application.get_env(:code_my_spec, :intake_conversation_process, true)

  # Same decisions, run in the caller. The state a process would carry is only
  # the in-flight marker, and inline work is never in flight when it returns.
  defp record_and_shape_inline(plan, text) do
    {reply, _state} = record_and_shape(plan, text, %{plan_id: plan.id, working: nil})
    reply
  end

  @doc "The conversation for this plan, started if it is not running."
  @spec ensure_started(Plan.t()) :: pid()
  def ensure_started(%Plan{} = plan) do
    case start_child(plan) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp start_child(plan) do
    DynamicSupervisor.start_child(
      CodeMySpec.Intake.ConversationSupervisor,
      {__MODULE__, plan}
    )
  end

  def child_spec(%Plan{} = plan) do
    %{id: {__MODULE__, plan.id}, start: {__MODULE__, :start_link, [plan]}, restart: :temporary}
  end

  def start_link(%Plan{} = plan) do
    GenServer.start_link(__MODULE__, plan, name: via(plan.id))
  end

  defp via(plan_id), do: {:via, Registry, {CodeMySpec.Intake.ConversationRegistry, plan_id}}

  @doc """
  Picks a conversation back up if the row says a call is out and none is.

  A deploy, a crash or an evicted machine takes the process and its task with
  it, and leaves `shaping_status: :thinking` on the row with nothing left to
  finish it. Nothing recovered that: the page rendered "Thinking…" and meant it
  forever. Measured the hard way — six deploys while somebody was using it.

  Idempotent by construction. The process knows whether it has work out, so a
  call here while it does is a no-op, and a call here when it does not is the
  work being restarted.
  """
  @spec resume(Plan.t()) :: :ok
  def resume(%Plan{shaping_status: :thinking} = plan) do
    if process?() do
      plan |> ensure_started() |> GenServer.cast(:resume)
    else
      :ok
    end
  end

  def resume(%Plan{}), do: :ok

  @impl true
  def init(%Plan{} = plan), do: {:ok, %{plan_id: plan.id, working: nil}, @idle_timeout}

  @impl true
  def handle_call({:said, text}, _from, %{plan_id: plan_id} = state) do
    # Re-read rather than trusting what the caller held. Two tabs are two
    # callers, and the one that submits second must build on the first's turn
    # rather than on the plan as it looked when its page loaded.
    case Intake.get_plan_by_id(plan_id) do
      nil ->
        {:reply, {:error, :no_plan}, state, @idle_timeout}

      plan ->
        {reply, state} = record_and_shape(plan, text, state)
        {:reply, reply, state, @idle_timeout}
    end
  end

  @impl true
  def handle_cast(:resume, %{working: ref} = state) when not is_nil(ref) do
    # Already out. The row said thinking and it is telling the truth.
    {:noreply, state, @idle_timeout}
  end

  def handle_cast(:resume, %{plan_id: plan_id} = state) do
    case Intake.get_plan_by_id(plan_id) do
      %Plan{shaping_status: :thinking} = plan ->
        Logger.info("[Intake.Conversation] resuming a call stranded on plan #{plan_id}")
        {:noreply, %{state | working: start_work(plan)}, @idle_timeout}

      _ ->
        {:noreply, state, @idle_timeout}
    end
  end

  @impl true
  # The task finished. `Intake.shape/2` has already written and broadcast the
  # result; this only clears the in-flight marker.
  def handle_info({ref, _result}, %{working: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | working: nil}, @idle_timeout}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{working: ref} = state) do
    Logger.warning(
      "[Intake.Conversation] shaping crashed on #{state.plan_id}: #{inspect(reason)}"
    )

    # A crashed call leaves the row saying thinking, and the row is what the
    # next page load reads. Say it failed instead, so the visitor is told rather
    # than left watching.
    state.plan_id |> Intake.get_plan_by_id() |> Intake.mark_shaping_failed()

    {:noreply, %{state | working: nil}, @idle_timeout}
  end

  def handle_info(:timeout, %{working: nil} = state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state, @idle_timeout}

  # Owned by this process rather than fired and forgotten, so it knows whether a
  # call is out. That is what makes `resume/1` safe to call on every page load:
  # without it, a second viewer arriving mid-call would start a second call.
  defp start_work(plan) do
    task =
      Task.Supervisor.async_nolink(CodeMySpec.TaskSupervisor, fn ->
        Intake.shape(plan)
      end)

    task.ref
  end

  # What a submission means is a property of where the conversation has got to,
  # which is on the row. The LiveView used to decide this from its own assigns
  # and pass the right event name, which is the same fact stored twice.
  defp record_and_shape(%Plan{status: :describing} = plan, text, state) do
    with {:ok, described} <- Intake.describe(plan, text), do: begin(described, state)
  end

  defp record_and_shape(%Plan{status: :answering} = plan, text, state) do
    with {:ok, recorded} <- Intake.record_turn(plan, plan.pending_question, text),
         do: begin(recorded, state)
  end

  # Past the questions. A submission here is a visitor typing into a box that
  # should not be on their screen, so it changes nothing and says so.
  defp record_and_shape(%Plan{status: status} = plan, _text, state) do
    Logger.info("[Intake.Conversation] ignoring a turn on a #{status} plan #{plan.id}")
    {{:ok, plan}, state}
  end

  defp begin(plan, state) do
    case Intake.mark_thinking(plan) do
      {:ok, thinking} -> {{:ok, run(thinking, state)}, working(state, thinking)}
      {:error, _} = error -> {error, state}
    end
  end

  # Owned when there is a process to own it, run here when there is not.
  #
  # `async_nolink/2` replies to whoever called it, so the inline path was
  # spawning a task whose `{ref, result}` landed in the LiveView — which has no
  # clause for it and died. The inline path has no process to be in flight, so
  # it does the work and returns the finished plan.
  defp run(plan, _state) do
    if process?(), do: plan, else: Intake.shape(plan)
  end

  defp working(state, plan) do
    if process?(), do: %{state | working: start_work(plan)}, else: state
  end
end
