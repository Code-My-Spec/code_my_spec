defmodule CodeMySpec.Provisioning.Tools.Starter do
  @moduledoc """
  The agent that started a provisioning run, held while it runs and told how
  it ended.

  1599c109: the starter ended its turn as told and nothing woke it when the
  run landed — eleven minutes idle, three times in a day. `RunLock` records
  it so `Agents.Waiting` holds its nudges; `tell/2` is the wake. A caller with
  no agent row (Claude Code) watches `devops_status` instead.
  """

  require Logger

  alias CodeMySpec.Agents
  alias CodeMySpec.Users.Scope

  @type t :: {Scope.t(), Ecto.UUID.t() | nil, String.t()}

  @spec new(Scope.t(), map(), String.t()) :: t()
  def new(scope, context, label), do: {scope, context[:agent_id], label}

  @doc "What `RunLock.with_lock/3` records as the run's holder."
  @spec lock_holder(t()) :: keyword()
  def lock_holder({_scope, agent_id, label}), do: [agent_id: agent_id, label: label]

  @doc "The tool reply's next step, once the run has started."
  @spec then_what(Ecto.UUID.t() | nil) :: String.t()
  def then_what(agent_id) when is_binary(agent_id),
    do: "you'll be messaged how it ends. Don't poll; end your turn if nothing else is waiting."

  def then_what(_agent_id), do: "call devops_status to watch it converge"

  @spec tell(t(), String.t()) :: :ok
  def tell({_scope, nil, _label}, _text), do: :ok

  def tell({scope, agent_id, label}, text) do
    case Agents.dispatch_message(scope, agent_id, text, :own_reply) do
      {:ok, _disposition, _message} ->
        :ok

      {:error, reason} ->
        Logger.info(
          "[Provisioning] could not tell agent #{agent_id} how #{label} ended: #{inspect(reason)}"
        )
    end
  end
end
