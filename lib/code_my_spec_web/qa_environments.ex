defmodule CodeMySpecWeb.QaEnvironments do
  @moduledoc """
  Owns the local environments `/dev/qa-agents` registers in a copy's own app,
  so analysis runs against this checkout.

  A registry entry dies with the process that made it, and a request's process
  ends with the request, so this one holds them. The copies themselves are
  rows; the entries are not. A restarted app re-registers every QA copy at its
  checkout as it starts, or analysis there fails with `:no_environment` until
  QA calls `/dev/qa-agents` again.
  """

  use Agent

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.WorkingCopies

  @label "qa"

  def start_link(opts) do
    root = Keyword.get(opts, :root, File.cwd!())
    Agent.start_link(fn -> restore(root) end, name: __MODULE__)
  end

  @doc "The label `/dev/qa-agents` gives the copies it records."
  def label, do: @label

  @doc "Register `copy_id` as running locally at `root`, owned by this process."
  def register(copy_id, root) do
    Agent.get(__MODULE__, fn _ -> register_local(copy_id, root) end)
  end

  defp restore(root) do
    root |> WorkingCopies.labelled_at(@label) |> Enum.each(&register_local(&1.id, root))
  end

  defp register_local(copy_id, root),
    do: ExecutionContexts.register({:working_copy, copy_id}, ExecutionContext.new(:local, root))
end
