defmodule CodeMySpec.Repo.SandboxAllowance do
  @moduledoc """
  A long-lived process taking its starter's sandbox connection.

  Per-project workers (`IncrementalGraph`, the promotion queue's `Worker`)
  outlive the caller that starts them and query from their own process. Under
  the SQL sandbox they need an allowance from a process that owns a connection,
  before their first query. No-op outside a sandboxed pool, or with no owner.
  """

  alias CodeMySpec.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @doc """
  Give `pid` the calling process's sandbox connection.

  The caller may hold none of its own — a Task reaches the sandbox through its
  `$callers` — so each of those is tried in turn. Granting from the Task alone
  answered `:not_found`, ignored, and the worker's first query found no
  connection: it stopped as though its test had ended, mid-test (2026-10-14).
  """
  @spec grant(pid()) :: pid()
  def grant(pid) when is_pid(pid) do
    if sandboxed?(), do: allow_from(owners(), pid)
    pid
  end

  @doc "This process and the callers it reaches the sandbox through."
  @spec owners() :: [pid()]
  def owners, do: [self() | Process.get(:"$callers", [])]

  @doc "Use the sandbox connection of the first of `owners` that has one."
  @spec take(pid() | [pid()] | nil) :: :ok
  def take(nil), do: :ok
  def take(owner) when is_pid(owner), do: take([owner])

  def take(owners) when is_list(owners) do
    if sandboxed?(), do: allow_from(owners, self())
    :ok
  end

  defp allow_from(owners, pid) do
    Enum.find(owners, &(is_pid(&1) and Sandbox.allow(Repo, &1, pid) != :not_found))
  end

  @doc "Whether the repo runs on the SQL sandbox (tests)."
  @spec sandboxed?() :: boolean()
  def sandboxed?, do: Application.get_env(:code_my_spec, Repo, [])[:pool] == Sandbox
end
