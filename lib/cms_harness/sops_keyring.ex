defmodule CmsHarness.SopsKeyring do
  @moduledoc """
  The harness's own in-memory sops age keyring.

  Holds the dev-scoped age keys the server hands over on channel join
  (`age_private_key_dev`/`age_private_key_test` — never a deploy
  environment's) only in this process's memory: never written to a file,
  an environment variable, or anywhere else on disk (story 1132). A
  restart holds nothing until the next join hands the keys over again —
  there is no file to read them back from, on purpose.

  `CmsHarness.SopsKeySocket` is the only reader: it answers the key
  command (`cms sops-key`, run by `sops` itself via `SOPS_AGE_KEY_CMD`)
  on this keyring's behalf, over a socket only the box's own user can
  reach.
  """

  use GenServer
  require Logger

  @name __MODULE__

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @name)
    GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, name))
  end

  @doc """
  Add each key this keyring does not already hold. Never writes anywhere;
  answers how many were newly added.
  """
  @spec install([String.t()], GenServer.server()) :: {:ok, non_neg_integer()}
  def install(keys, server \\ @name)
  def install([], _server), do: {:ok, 0}
  def install(keys, server) when is_list(keys), do: GenServer.call(server, {:install, keys})

  @doc "The keys currently held, in no particular order, or `[]` if none."
  @spec keys(GenServer.server()) :: [String.t()]
  def keys(server \\ @name), do: GenServer.call(server, :keys)

  @doc "Whether this keyring currently holds any key at all."
  @spec holding_key?(GenServer.server()) :: boolean()
  def holding_key?(server \\ @name), do: keys(server) != []

  @impl true
  def init(:ok), do: {:ok, MapSet.new()}

  @impl true
  def handle_call({:install, keys}, _from, held) do
    valid = keys |> Enum.filter(&valid?/1) |> Enum.uniq()
    new = Enum.reject(valid, &MapSet.member?(held, &1))

    if new != [] do
      Logger.info(
        "[CmsHarness] holding #{MapSet.size(held) + length(new)} age key(s) in memory " <>
          "(#{length(new)} new)"
      )
    end

    {:reply, {:ok, length(new)}, Enum.into(new, held)}
  end

  def handle_call(:keys, _from, held), do: {:reply, MapSet.to_list(held), held}

  defp valid?(key), do: is_binary(key) and String.starts_with?(key, "AGE-SECRET-KEY-")
end
