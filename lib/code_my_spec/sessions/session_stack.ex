defmodule CodeMySpec.Sessions.SessionStack do
  @moduledoc """
  Manages the session stack — lists active sessions in priority order.
  """

  alias CodeMySpec.Sessions.SessionsRepository

  @doc """
  List active sessions sorted by priority (highest first).

  Returns `{:ok, sessions}` or passes through repository errors.
  """
  def list_active(env) do
    case SessionsRepository.list_sessions(env) do
      {:ok, []} ->
        {:ok, []}

      {:ok, sessions} ->
        max_priority = sessions |> Enum.map(& &1.priority) |> Enum.max()
        {:ok, Enum.filter(sessions, &(&1.priority == max_priority))}

      error ->
        error
    end
  end
end
