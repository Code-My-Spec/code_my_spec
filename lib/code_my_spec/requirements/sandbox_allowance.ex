defmodule CodeMySpec.Requirements.SandboxAllowance do
  @moduledoc """
  A long-lived requirements process taking its starter's sandbox connection.

  `GraphWatcher` and `IncrementalGraph` outlive the caller that starts them and
  query from their own process. Under the SQL sandbox they need an allowance
  from a process that owns a connection, before their first query. No-op
  outside a sandboxed pool, or with no owner.
  """

  alias CodeMySpec.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @doc "Give `pid` the calling process's sandbox connection."
  @spec grant(pid()) :: pid()
  def grant(pid) when is_pid(pid) do
    if sandboxed?(), do: _ = Sandbox.allow(Repo, self(), pid)
    pid
  end

  @doc "Use `owner`'s sandbox connection from the calling process."
  @spec take(pid() | nil) :: :ok
  def take(nil), do: :ok

  def take(owner) when is_pid(owner) do
    if sandboxed?(), do: _ = Sandbox.allow(Repo, owner, self())
    :ok
  end

  defp sandboxed?, do: Application.get_env(:code_my_spec, Repo, [])[:pool] == Sandbox
end
