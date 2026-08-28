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
      record_and_shape(plan, text)
    end
  end

  defp process?, do: Application.get_env(:code_my_spec, :intake_conversation_process, true)

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

  @impl true
  def init(%Plan{} = plan), do: {:ok, %{plan_id: plan.id}, @idle_timeout}

  @impl true
  def handle_call({:said, text}, _from, %{plan_id: plan_id} = state) do
    # Re-read rather than trusting what the caller held. Two tabs are two
    # callers, and the one that submits second must build on the first's turn
    # rather than on the plan as it looked when its page loaded.
    case Intake.get_plan_by_id(plan_id) do
      nil ->
        {:reply, {:error, :no_plan}, state, @idle_timeout}

      plan ->
        {:reply, record_and_shape(plan, text), state, @idle_timeout}
    end
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state, @idle_timeout}

  # What a submission means is a property of where the conversation has got to,
  # which is on the row. The LiveView used to decide this from its own assigns
  # and pass the right event name, which is the same fact stored twice.
  defp record_and_shape(%Plan{status: :describing} = plan, text) do
    with {:ok, described} <- Intake.describe(plan, text) do
      Intake.shape_async(described)
    end
  end

  defp record_and_shape(%Plan{status: :answering} = plan, text) do
    with {:ok, recorded} <- Intake.record_turn(plan, plan.pending_question, text) do
      Intake.shape_async(recorded)
    end
  end

  # Past the questions. A submission here is a visitor typing into a box that
  # should not be on their screen, so it changes nothing and says so.
  defp record_and_shape(%Plan{status: status} = plan, _text) do
    Logger.info("[Intake.Conversation] ignoring a turn on a #{status} plan #{plan.id}")
    {:ok, plan}
  end
end
