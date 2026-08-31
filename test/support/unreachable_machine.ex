defmodule CodeMySpecTest.UnreachableMachine do
  @moduledoc """
  A machine this server cannot reach.

  Not the same as a machine that says the agent is gone. The process is on a
  box we cannot currently talk to, so it is very likely still running and
  still spending — and the two want completely different things from whoever
  is reading.
  """
  # Named, never called: a criterion puts it in config and the server picks it
  # up. It lives on the app side because that is the side it is on — it
  # implements a *server* behaviour, and `CodeMySpecSpex` may not reference
  # `CodeMySpec`.
  @behaviour CodeMySpec.Agents.Transport

  @impl true
  def start_agent(_copy, _agent, _timeout), do: {:error, :harness_not_connected}

  @impl true
  def message_agent(_copy, _agent, _message, _timeout), do: {:error, :harness_not_connected}

  @impl true
  def dispatch_message(_copy, _agent, _ref, _message, _timeout),
    do: {:error, :harness_not_connected}

  @impl true
  def withdraw_message(_copy, _agent, _ref, _timeout), do: {:error, :harness_not_connected}

  @impl true
  def stop_agent(_copy, _agent, _timeout), do: {:error, :harness_not_connected}
  @impl true
  def call_machine_tool(_working_copy_id, _tool, _arguments, _timeout),
    do: {:error, :harness_unreachable}

end
