defmodule CodeMySpec.AppInstances.Tools.Starter do
  @moduledoc """
  The agent that started an app run (stop/restart/start), held while it runs
  and told how it ended.

  Same shape as `CodeMySpec.Provisioning.Tools.Starter` (1599c109's fix for a
  run's starter left idle with nothing to wake it when the run landed) --
  kept as its own copy rather than a cross-boundary dependency on
  `Provisioning`, which `WorkingCopies` has never depended on. A caller with
  no agent row (Claude Code, or any caller outside an agent session) is told
  to call the tool again instead -- there is no `devops_status` equivalent
  for a working copy's own app runs to watch.
  """

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Users.Scope

  @type t :: {Scope.t(), Ecto.UUID.t() | nil, String.t()}

  @spec new(Scope.t(), map(), String.t()) :: t()
  def new(scope, context, label), do: {scope, context[:agent_id], label}

  @doc "What `AppRunLock.with_lock/3` records as the run's holder."
  @spec lock_holder(t()) :: keyword()
  def lock_holder({_scope, agent_id, label}), do: [agent_id: agent_id, label: label]

  @doc "The tool reply's next step, once the run has started."
  @spec then_what(Ecto.UUID.t() | nil) :: String.t()
  def then_what(agent_id) when is_binary(agent_id),
    do: "you'll be messaged how it ends. Don't poll; end your turn if nothing else is waiting."

  def then_what(_agent_id),
    do: "call this tool again to check -- a run already in progress answers at once"

  @doc """
  Tell the agent how a run on app instance `id` ended. A busy agent's notice
  waits for its turn to end, so an earlier one still waiting is withdrawn:
  only the newest says how the app is. Five runs while an agent worked once
  arrived as five notices, the first ones long out of date (issue 543c6d39).
  """
  @spec tell(t(), String.t(), String.t()) :: :ok
  def tell({_scope, nil, _label}, _id, _text), do: :ok

  def tell({scope, agent_id, label}, id, text) do
    settled({scope, agent_id, label}, id)

    case Agents.dispatch_message(scope, agent_id, text, :own_reply) do
      {:ok, :queued, message} ->
        :persistent_term.put(key(agent_id, id), message.delivery_ref)

      {:ok, _disposition, _message} ->
        :ok

      {:error, reason} ->
        Logger.info(
          "[WorkingCopies] could not tell agent #{agent_id} how #{label} ended: #{inspect(reason)}"
        )
    end

    :ok
  end

  @doc """
  The agent has heard how app instance `id` is from a newer source (a reply
  it read itself), so a notice still waiting for it is withdrawn.
  """
  @spec settled(t(), String.t()) :: :ok
  def settled({_scope, nil, _label}, _id), do: :ok

  def settled({scope, agent_id, _label}, id) do
    case :persistent_term.get(key(agent_id, id), nil) do
      nil ->
        :ok

      ref ->
        :persistent_term.erase(key(agent_id, id))
        _ = Agents.withdraw_message(scope, agent_id, ref)
        :ok
    end
  end

  defp key(agent_id, id), do: {__MODULE__, :waiting, agent_id, id}
end
