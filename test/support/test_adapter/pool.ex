defmodule CodeMySpec.Support.TestAdapter.Pool do
  @moduledoc """
  A pool of pre-cloned test repository directories.

  Instead of rsync-ing a fresh copy for every test (slow), this pool maintains
  reusable directories. When a test needs a repo, it checks out from the pool.
  When done, it checks in and the directory is reset via git for the next test.

  ## Usage

      # In test setup
      {:ok, path} = Pool.checkout(:code_repo, include_deps: true, include_build: true)

      # In on_exit
      Pool.checkin(path)

  """

  use GenServer

  @code_repo_fixture "../code_my_spec_test_repos/test_phoenix_project"
  @content_repo_fixture "../code_my_spec_test_repos/test_content_repo"

  defstruct [
    # Available directories ready for checkout: %{config_key => [paths]}
    available: %{},
    # Checked out directories: %{path => config_key}
    checked_out: %{},
    # Counter for generating unique directory names
    counter: 0
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checkout a directory from the pool.

  Returns an existing clean directory if one is available,
  otherwise creates a new one via rsync (with all files including deps, build, git).

  ## Options
    * `:repo_type` - :code_repo or :content_repo (default: :code_repo)
  """
  def checkout(opts \\ []) do
    GenServer.call(__MODULE__, {:checkout, opts}, :infinity)
  end

  @doc """
  Return a directory to the pool.

  Resets git state (clears staged/unstaged changes) before making it available.
  """
  def checkin(path) do
    GenServer.call(__MODULE__, {:checkin, path}, :infinity)
  end

  @doc """
  Get pool stats for debugging.
  """
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    sweep_dead_roots()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:checkout, opts}, _from, state) do
    repo_type = Keyword.get(opts, :repo_type, :code_repo)
    available_for_type = Map.get(state.available, repo_type, [])

    case available_for_type do
      [path | rest] ->
        # Reuse existing directory - reset it first
        reset_git_state(path)

        new_available = Map.put(state.available, repo_type, rest)
        new_checked_out = Map.put(state.checked_out, path, repo_type)

        {:reply, {:ok, path}, %{state | available: new_available, checked_out: new_checked_out}}

      [] ->
        # No available directory, create new one
        {path, new_counter} = create_directory(repo_type, state.counter)
        new_checked_out = Map.put(state.checked_out, path, repo_type)

        {:reply, {:ok, path}, %{state | checked_out: new_checked_out, counter: new_counter}}
    end
  end

  @impl true
  def handle_call({:checkin, path}, _from, state) do
    case Map.pop(state.checked_out, path) do
      {nil, _} ->
        # Not tracked, just ignore
        {:reply, :ok, state}

      {config_key, new_checked_out} ->
        # Reset and return to pool
        reset_git_state(path)

        available_for_config = Map.get(state.available, config_key, [])
        new_available = Map.put(state.available, config_key, [path | available_for_config])

        {:reply, :ok, %{state | available: new_available, checked_out: new_checked_out}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      available: Enum.map(state.available, fn {k, v} -> {k, length(v)} end) |> Map.new(),
      checked_out: map_size(state.checked_out),
      counter: state.counter
    }

    {:reply, stats, state}
  end

  # Private functions

  # One pool root per OS process.
  #
  # The counter this names directories from lives in *this* GenServer's state,
  # so it starts at zero in every suite. Two suites running at once — the normal
  # case here, one working copy per agent — therefore both created
  # `pool_code_repo_1` and both handed it out. Not contention over a scarce
  # resource: two processes with the same working tree, one running `git reset`
  # and `File.rm_rf` while the other asserted against it.
  #
  # It surfaced as `SpecAlignment` finding no misalignment in a tree whose specs
  # another suite had just deleted — "Expected truthy, got false", passing on
  # every rerun in isolation. `spec_alignment_test.exs` already guards the
  # in-suite version of this and says so in a comment; no in-suite guard can see
  # another OS process.
  #
  # Keyed by OS pid rather than a random suffix so the directories of a dead run
  # can be recognised and swept.
  defp pool_root do
    root = Path.join("../code_my_spec_test_repos", "run_#{System.pid()}")
    File.mkdir_p!(root)
    root
  end

  # Roots from runs that are no longer alive. A crashed suite never reaches
  # `checkin`, and each root holds a full repo copy including `deps` and
  # `_build`, so leaving them costs real disk.
  defp sweep_dead_roots do
    case File.ls("../code_my_spec_test_repos") do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, "run_"))
        |> Enum.reject(&owned_or_alive?/1)
        |> Enum.each(&File.rm_rf(Path.join("../code_my_spec_test_repos", &1)))

      {:error, _} ->
        :ok
    end
  end

  defp owned_or_alive?("run_" <> pid), do: pid == System.pid() or alive?(pid)

  # `kill -0` asks whether the pid exists without signalling it. A non-numeric
  # leftover answers "not alive", which is the safe direction: it gets swept.
  defp alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp create_directory(repo_type, counter) do
    fixture_path = fixture_for_type(repo_type)
    new_counter = counter + 1
    dest_path = Path.join(pool_root(), "pool_#{repo_type}_#{new_counter}")

    File.mkdir_p!(dest_path)

    # The fixture repositories are no longer cloned at test boot — that pull ran
    # on every `mix test`, in a directory every worktree shares by symlink. So
    # the first test to want a real project is where a missing one surfaces, and
    # it has to say what to run rather than fail as an rsync error naming a path.
    if not File.exists?(fixture_path) do
      raise """
      No fixture repository at #{fixture_path}.

      Only the analyzer tests need a real project on disk, so it is not cloned
      at test boot any more. Run:

          mix cms.test_fixtures

      That clones both fixture repositories and regenerates the recorded
      analyzer output in test/fixtures/analyzer_output/.
      """
    end

    # Copy everything (deps, build, git) - only exclude .DS_Store
    args = ["-a", "--exclude", ".DS_Store", "#{fixture_path}/", "#{dest_path}/"]

    case System.cmd("rsync", args) do
      {_, 0} ->
        {dest_path, new_counter}

      {output, code} ->
        raise "Failed to create pool directory: #{output}, exit code: #{code}"
    end
  end

  defp fixture_for_type(:code_repo), do: @code_repo_fixture
  defp fixture_for_type(:content_repo), do: @content_repo_fixture

  defp reset_git_state(path) do
    if File.exists?(Path.join(path, ".git")) do
      # Reset main repo
      System.cmd("git", ["checkout", "."], cd: path, stderr_to_stdout: true)
      System.cmd("git", ["clean", "-fd"], cd: path, stderr_to_stdout: true)
    end

    :ok
  end
end
