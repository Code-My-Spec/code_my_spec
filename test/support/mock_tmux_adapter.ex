defmodule CodeMySpec.Environments.MockTmuxAdapter do
  @moduledoc """
  Mock implementation of TmuxAdapter for testing Cli environment in isolation.

  This mock allows testing Cli logic without requiring actual tmux.
  """

  @doc """
  Mock inside_tmux? - returns true by default.

  Can be configured via process dictionary for specific tests:
  ```
  Process.put(:mock_inside_tmux, false)
  ```
  """
  def inside_tmux? do
    Process.get(:mock_inside_tmux, true)
    true
  end

  @doc """
  Mock get_current_session - returns a mock session name.
  """
  def get_current_session do
    {:ok, "mock-session"}
  end

  @doc """
  Mock create_window - returns a predictable window ID.
  """
  def create_window(window_name) do
    # Store window name in process dictionary to track created windows
    windows = Process.get(:mock_windows, MapSet.new())
    Process.put(:mock_windows, MapSet.put(windows, window_name))

    {:ok, "@mock-#{window_name}"}
  end

  @doc """
  Mock kill_window - always succeeds (idempotent).
  """
  def kill_window(window_name) do
    # Remove from tracked windows
    windows = Process.get(:mock_windows, MapSet.new())
    Process.put(:mock_windows, MapSet.delete(windows, window_name))

    :ok
  end

  @doc """
  Mock send_keys - records the command and returns success.
  """
  def send_keys(window_name, command) do
    # Store sent commands for verification if needed
    commands = Process.get(:mock_commands, [])
    Process.put(:mock_commands, [{window_name, command} | commands])

    :ok
  end

  @doc """
  Mock send_keys_to_pane - records the command and returns success.
  """
  def send_keys_to_pane(pane_id, command) do
    # Store sent commands for verification if needed
    commands = Process.get(:mock_pane_commands, [])
    Process.put(:mock_pane_commands, [{pane_id, command} | commands])

    :ok
  end

  @doc """
  Mock list_windows - returns formatted output of tracked windows.
  """
  def list_windows(_format \\ nil) do
    windows = Process.get(:mock_windows, MapSet.new())
    output = windows |> Enum.join("\n")
    {:ok, output}
  end

  @doc """
  Mock window_exists? - checks if window was created.
  """
  def window_exists?(window_name) do
    windows = Process.get(:mock_windows, MapSet.new())
    MapSet.member?(windows, window_name)
  end

  @doc """
  Mock pane_exists? - checks if pane with the title exists.
  """
  def pane_exists?(title) do
    case find_pane_by_title(title) do
      {:ok, _pane_id} -> true
      {:error, :not_found} -> false
    end
  end

  @doc """
  Mock find_pane_by_title - finds a pane by its title.
  """
  def find_pane_by_title(title) do
    titles = Process.get(:mock_pane_titles, %{})

    case Enum.find(titles, fn {_pane_id, pane_title} -> pane_title == title end) do
      {pane_id, _title} -> {:ok, pane_id}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Mock enable_mouse_mode - always succeeds.
  """
  def enable_mouse_mode do
    :ok
  end

  @doc """
  Reset mock state - useful in test setup.
  """
  def reset! do
    Process.delete(:mock_windows)
    Process.delete(:mock_commands)
    Process.delete(:mock_pane_commands)
    Process.delete(:mock_panes)
    Process.delete(:mock_pane_titles)
    Process.delete(:mock_joined_panes)
    Process.delete(:mock_broken_windows)
  end

  @doc """
  Get commands sent via send_keys for verification.
  """
  def get_sent_commands do
    Process.get(:mock_commands, [])
    |> Enum.reverse()
  end

  @doc """
  Mock split_pane - creates a mock pane and returns pane ID.
  """
  def split_pane(_target, _direction, _size) do
    pane_id = "@mock-pane-#{:rand.uniform(1000)}"

    # Store pane ID in process dictionary to track created panes
    panes = Process.get(:mock_panes, MapSet.new())
    Process.put(:mock_panes, MapSet.put(panes, pane_id))

    {:ok, pane_id}
  end

  @doc """
  Mock set_pane_title - stores the title for later retrieval.
  """
  def set_pane_title(pane_id, title) do
    # Store pane titles in process dictionary
    titles = Process.get(:mock_pane_titles, %{})
    Process.put(:mock_pane_titles, Map.put(titles, pane_id, title))

    :ok
  end

  @doc """
  Mock enter_copy_mode - always succeeds.
  """
  def enter_copy_mode(_pane_id) do
    :ok
  end

  @doc """
  Mock kill_pane - removes pane from tracking (idempotent).
  """
  def kill_pane(pane_id) do
    # Remove from tracked panes
    panes = Process.get(:mock_panes, MapSet.new())
    Process.put(:mock_panes, MapSet.delete(panes, pane_id))

    # Remove title
    titles = Process.get(:mock_pane_titles, %{})
    Process.put(:mock_pane_titles, Map.delete(titles, pane_id))

    :ok
  end

  @doc """
  Mock list_panes - returns formatted output of tracked panes.
  """
  def list_panes(_target, _format) do
    panes = Process.get(:mock_panes, MapSet.new())
    titles = Process.get(:mock_pane_titles, %{})

    output =
      Enum.map_join(panes, "\n", fn pane_id ->
        title = Map.get(titles, pane_id, "")
        "#{pane_id}:#{title}"
      end)

    {:ok, output}
  end

  @doc """
  Mock get_pane_property - returns property value for a pane.
  """
  def get_pane_property(pane_id, "\#{pane_title}") do
    titles = Process.get(:mock_pane_titles, %{})

    case Map.get(titles, pane_id) do
      nil -> {:error, "pane not found"}
      title -> {:ok, title}
    end
  end

  def get_pane_property(_pane_id, _property) do
    {:ok, "mock-value"}
  end

  @doc """
  Mock join_pane - joins a pane from source window into current window.
  """
  def join_pane(source_window, _opts \\ []) do
    # In mock, we simulate this by creating a new pane
    # and tracking which window it came from
    pane_id = "@mock-pane-#{:rand.uniform(1000)}"

    panes = Process.get(:mock_panes, MapSet.new())
    Process.put(:mock_panes, MapSet.put(panes, pane_id))

    # Track source window for verification
    joined_panes = Process.get(:mock_joined_panes, %{})
    Process.put(:mock_joined_panes, Map.put(joined_panes, pane_id, source_window))

    {:ok, pane_id}
  end

  @doc """
  Mock break_pane - breaks a pane out into its own window.
  """
  def break_pane(pane_id, opts \\ []) do
    window_name = Keyword.get(opts, :window_name)

    # Remove from tracked panes
    panes = Process.get(:mock_panes, MapSet.new())
    Process.put(:mock_panes, MapSet.delete(panes, pane_id))

    # Remove from joined panes tracking
    joined_panes = Process.get(:mock_joined_panes, %{})
    Process.put(:mock_joined_panes, Map.delete(joined_panes, pane_id))

    # Track broken out windows if window_name provided
    if window_name do
      broken_windows = Process.get(:mock_broken_windows, MapSet.new())
      Process.put(:mock_broken_windows, MapSet.put(broken_windows, window_name))
    end

    :ok
  end
end
