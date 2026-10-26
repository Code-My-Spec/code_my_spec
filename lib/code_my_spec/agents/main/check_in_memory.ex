defmodule CodeMySpec.Agents.Main.CheckInMemory do
  @moduledoc """
  The requirement count the previous check-in saw, per project.

  Criterion 2477: "2741/2858 satisfied" alone says nothing about whether the
  night moved; the change since the last look does. Kept in memory: a restart
  costs one check-in without a delta, which is all it is worth.
  """

  @doc "Remember `counts` for the project and answer what was remembered before."
  @spec swap(Ecto.UUID.t() | nil, map() | term()) :: map() | nil
  def swap(nil, _counts), do: nil

  def swap(project_id, %{total: _, satisfied: _} = counts) do
    key = {__MODULE__, project_id}
    previous = :persistent_term.get(key, nil)
    if previous != counts, do: :persistent_term.put(key, counts)
    previous
  end

  def swap(project_id, _unavailable), do: :persistent_term.get({__MODULE__, project_id}, nil)
end
