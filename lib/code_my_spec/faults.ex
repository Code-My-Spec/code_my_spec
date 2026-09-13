defmodule CodeMySpec.Faults do
  @moduledoc """
  Break one caller's world without breaking everybody's.

  Issue `0fb7bf03`. Nine criteria across five stories are all about how the
  system behaves when something underneath it is broken, and not one of them
  could be exercised, because the only seams were node-global: flip
  `:main_agent_digest_source` and every project on the box loses its digest;
  swap `CodeMySpec.Intake[:shaper]` and every visitor's intake breaks for as
  long as it is swapped. On a shared dev box that is an outage, so five QA
  passes in a row reasoned their way to the same refusal and left the criteria
  verified-by-reading — the state they were in before anybody wrote a story.

  The precedent is `/dev/sign-in`, which exists so QA does not have to fight
  over the shared `/dev/mailbox`. This is the same idea applied to failure
  rather than to auth: a fault is injected against **one key** — a project, an
  intake session, a working copy — and only work carrying that key sees it.

  ## Keys are whatever the seam already carries

  No new identifier. `Cadence.digest/1` has a scope with a project id;
  `Shaper.shape/2` has a plan with the visitor's session token. Each seam asks
  about the key it already holds, which is also what makes the blast radius
  obvious at the call site.

  ## Unknown names are refused

  `inject/2` accepts only the faults something actually checks for. A name
  nothing reads would be injected happily, never fire, and read as "the product
  handled it" — a false pass, which is worse than no seam at all.

  ## Clear it when you are done, because you are not the only caller

  A fault is scoped to a key, not to your request, so everything else that
  carries that key sees it too — including work nobody started by hand. Both
  times `digest_unavailable` was injected to exercise criterion 3333, the
  project's own cadence came round while it was in force and raised "the
  check-in could not be assembled" against a ledger that was fine. Two issues
  filed, both dismissed.

  That is the seam working rather than a flaw in it — a fault a scheduled tick
  cannot see would not be testing the thing the criterion is about. It is a
  reason to clear promptly, and a reason the dismissal is worth writing out: the
  next reader of that issue would otherwise go looking for an outage that did
  not happen.

  ## It cannot outlive a boot, and nothing in the release writes to it

  ETS, owned by this process, gone on restart. The only writer is
  `CodeMySpecWeb.DevFaultController`, which lives behind `:dev_routes` and is
  compile-time absent from the release — so in production the table is empty and
  every check is one lookup that finds nothing.
  """

  use Boundary, top_level?: true, deps: [], exports: []
  use GenServer

  @table __MODULE__

  @faults %{
    digest_unavailable: "the main agent's digest cannot be assembled (criterion 3333)",
    intake_shaper_fails: "the intake shaper errors instead of answering (criterion 3375)",
    graph_recompute_fails:
      "this project's graph watcher raises instead of recomputing (criterion 3248)",
    agent_stays_silent:
      "this agent (key is its id) counts as never having spoken, so a restart " <>
        "does not resolve itself (criteria 3292, 3293, 3308)"
  }

  @doc "What can be injected, and what each one does."
  @spec known() :: %{atom() => String.t()}
  def known, do: @faults

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: opts[:name] || __MODULE__)

  @impl GenServer
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Makes `fault` happen to work carrying `key`, and to nothing else.

  Refuses a name no seam reads — see the moduledoc on why a silently inert
  fault is the one outcome worth preventing.
  """
  @spec inject(String.t(), atom()) :: :ok | {:error, {:unknown_fault, [atom()]}}
  def inject(key, fault) when is_binary(key) and is_map_key(@faults, fault) do
    :ets.insert(@table, {{key, fault}})
    :ok
  end

  def inject(key, _fault) when is_binary(key), do: {:error, {:unknown_fault, Map.keys(@faults)}}

  @doc "Puts it back."
  @spec clear(String.t(), atom()) :: :ok
  def clear(key, fault) when is_binary(key) do
    :ets.delete(@table, {key, fault})
    :ok
  end

  @doc """
  Whether this key is currently broken in this particular way.

  `nil` is not a key. A seam whose scope is unknown — a plan with no session
  token, a scope with no project — is the ordinary case rather than a broken
  one, and matching it would make one injection hit every anonymous caller.
  """
  @spec active?(String.t() | nil, atom()) :: boolean()
  def active?(nil, _fault), do: false

  def active?(key, fault) when is_binary(key), do: :ets.member(@table, {key, fault})

  @doc "Everything currently injected, so a caller can see what it left behind."
  @spec list() :: [%{key: String.t(), fault: atom()}]
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {{key, fault}} -> %{key: key, fault: fault} end)
  end

  @doc "Clears the lot. Answers how many it removed."
  @spec clear_all() :: non_neg_integer()
  def clear_all do
    count = :ets.info(@table, :size)
    :ets.delete_all_objects(@table)
    count
  end
end
