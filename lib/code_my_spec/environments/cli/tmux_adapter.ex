defmodule CodeMySpec.Environments.Cli.TmuxAdapter do
  require Logger

  @moduledoc """
  Adapter for tmux operations, enabling Cli environment to be tested without actual tmux dependency.

  This module wraps tmux CLI commands and can be mocked in tests for testability.
  """

  @doc """
  Check if currently running inside a tmux session.

  Returns true if the TMUX environment variable is set and non-empty.
  """
  @spec inside_tmux?() :: boolean()
  def inside_tmux? do
    case System.get_env("TMUX") do
      nil -> false
      "" -> false
      _value -> true
    end
  end

  @doc """
  Get the name of the current tmux session.

  Returns {:ok, session_name} if inside tmux, {:error, reason} otherwise.
  """
  @spec get_current_session() :: {:ok, String.t()} | {:error, term()}
  def get_current_session do
    case System.cmd("tmux", ["display-message", "-p", "\#{session_name}"]) do
      {session, 0} ->
        {:ok, String.trim(session)}

      {error, _code} ->
        {:error, error}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Create a new tmux window with specified name.

  Returns {:ok, window_id} on success, {:error, reason} on failure.
  """
  @spec create_window(window_name :: String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_window(window_name) do
    case get_current_session() do
      {:ok, session} ->
        case System.cmd("tmux", [
               "new-window",
               "-t",
               session,
               "-n",
               window_name,
               "-d",
               # Don't switch to it
               "-P",
               "-F",
               "\#{window_id}"
             ]) do
          {window_id, 0} -> {:ok, String.trim(window_id)}
          {error, _code} -> {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Kill/close a tmux window by name.

  Returns :ok on success, even if the window doesn't exist (idempotent).
  Returns {:error, reason} only for actual tmux failures.
  """
  @spec kill_window(window_name :: String.t()) :: :ok | {:error, term()}
  def kill_window(window_name) do
    Logger.info("Attempting to kill window: #{window_name}")

    case get_current_session() do
      {:ok, session} ->
        target = "#{session}:#{window_name}"
        Logger.info("Kill window target: #{target}")
        kill_window_at(target, window_name)

      {:error, reason} ->
        Logger.warning("Could not get current session: #{inspect(reason)}")
        :ok
    end
  end

  defp kill_window_at(target, window_name) do
    case System.cmd("tmux", ["kill-window", "-t", target]) do
      {_output, 0} ->
        Logger.info("Successfully killed window #{window_name}")
        :ok

      {error, code} when is_binary(error) ->
        Logger.warning("kill_window failed: #{inspect(error)} (exit code: #{code})")

        if error == "" or String.contains?(error, "can't find window") or
             String.contains?(error, "no such window") do
          Logger.info("Window #{window_name} doesn't exist, treating as success")
          :ok
        else
          {:error, error}
        end

      {error, _code} ->
        {:error, error}
    end
  end

  @doc """
  Send a command string to a tmux window.

  The command will be sent followed by Enter (C-m) to execute it.
  Uses -l flag to send as literal UTF-8 characters.
  Returns :ok on success, {:error, reason} on failure.
  """
  @spec send_keys(window_name :: String.t(), command :: String.t()) :: :ok | {:error, term()}
  def send_keys(window_name, command) do
    case get_current_session() do
      {:ok, session} -> send_keys_with_session(session, window_name, command)
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_keys_with_session(session, window_name, command) do
    case System.cmd("tmux", [
           "send-keys",
           "-l",
           "-t",
           "#{session}:#{window_name}",
           command
         ]) do
      {_output, 0} ->
        # Send Enter separately since -l makes C-m literal
        case System.cmd("tmux", ["send-keys", "-t", "#{session}:#{window_name}", "C-m"]) do
          {_output, 0} -> :ok
          {error, _code} -> {:error, error}
        end

      {error, _code} ->
        {:error, error}
    end
  end

  @doc """
  Send a command string directly to a tmux pane by ID.

  The command will be sent followed by Enter (C-m) to execute it.
  Uses -l flag to send as literal UTF-8 characters.
  Returns :ok on success, {:error, reason} on failure.
  """
  @spec send_keys_to_pane(pane_id :: String.t(), command :: String.t()) :: :ok | {:error, term()}
  def send_keys_to_pane(pane_id, command) do
    case System.cmd("tmux", ["send-keys", "-l", "-t", pane_id, command]) do
      {_output, 0} ->
        # Send Enter separately since -l makes C-m literal
        case System.cmd("tmux", ["send-keys", "-t", pane_id, "C-m"]) do
          {_output, 0} -> :ok
          {error, _code} -> {:error, error}
        end

      {error, _code} ->
        {:error, error}
    end
  end

  @doc """
  List all windows in the current session with a format string.

  Returns {:ok, output} on success, {:error, reason} on failure.
  """
  @spec list_windows(format :: String.t()) :: {:ok, String.t()} | {:error, term()}
  def list_windows(format \\ "\#{window_name}") do
    case get_current_session() do
      {:ok, session} ->
        case System.cmd("tmux", ["list-windows", "-t", session, "-F", format]) do
          {output, 0} -> {:ok, output}
          {error, _code} -> {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if a tmux window exists by name.

  Returns true if the window exists, false otherwise.
  """
  @spec window_exists?(window_name :: String.t()) :: boolean()
  def window_exists?(window_name) do
    case get_current_session() do
      {:ok, session} -> window_in_list?(session, window_name)
      {:error, _} -> false
    end
  rescue
    _error -> false
  end

  defp window_in_list?(session, window_name) do
    case System.cmd("tmux", [
           "list-windows",
           "-t",
           session,
           "-F",
           "\#{window_name}"
         ]) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split("\n")
        |> Enum.any?(&(&1 == window_name))

      {_error, _code} ->
        false
    end
  end

  @doc """
  Check if a pane with the specified title exists.

  Returns true if a pane with the title exists, false otherwise.
  """
  @spec pane_exists?(title :: String.t()) :: boolean()
  def pane_exists?(title) do
    case find_pane_by_title(title) do
      {:ok, _pane_id} -> true
      {:error, :not_found} -> false
    end
  end

  @doc """
  Find a pane by its title.

  Returns {:ok, pane_id} if found, {:error, :not_found} otherwise.
  """
  @spec find_pane_by_title(title :: String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def find_pane_by_title(title) do
    with {:ok, session} <- get_current_session(),
         {:ok, output} <- list_panes(session, "\#{pane_id}:\#{pane_title}") do
      panes =
        output
        |> String.trim()
        |> String.split("\n")
        |> Enum.map(fn line ->
          case String.split(line, ":", parts: 2) do
            [pane_id, pane_title] -> {pane_id, pane_title}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      case Enum.find(panes, fn {_id, pane_title} -> pane_title == title end) do
        {pane_id, _title} -> {:ok, String.trim(pane_id)}
        nil -> {:error, :not_found}
      end
    else
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Split a pane in a tmux window.

  Returns {:ok, pane_id} on success, {:error, reason} on failure.
  """
  @spec split_pane(target :: String.t(), direction :: String.t(), size :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def split_pane(target, direction, size) do
    case System.cmd("tmux", [
           "split-window",
           direction,
           "-l",
           size,
           "-t",
           target,
           "-P",
           "-F",
           "\#{pane_id}",
           "-d"
         ]) do
      {pane_id, 0} -> {:ok, String.trim(pane_id)}
      {error, _code} -> {:error, error}
    end
  end

  @doc """
  Set the title of a tmux pane.

  Returns :ok on success, {:error, reason} on failure.
  """
  @spec set_pane_title(pane_id :: String.t(), title :: String.t()) :: :ok | {:error, term()}
  def set_pane_title(pane_id, title) do
    case System.cmd("tmux", ["select-pane", "-t", pane_id, "-T", title]) do
      {_output, 0} -> :ok
      {error, _code} -> {:error, error}
    end
  end

  @doc """
  Enter copy mode in a tmux pane.

  Returns :ok on success, {:error, reason} on failure.
  """
  @spec enter_copy_mode(pane_id :: String.t()) :: :ok | {:error, term()}
  def enter_copy_mode(pane_id) do
    case System.cmd("tmux", ["copy-mode", "-t", pane_id]) do
      {_output, 0} -> :ok
      {error, _code} -> {:error, error}
    end
  end

  @doc """
  Enable mouse mode globally for tmux.

  This allows scrolling with the mouse wheel and clicking to select panes.
  Returns :ok on success, {:error, reason} on failure.
  """
  @spec enable_mouse_mode() :: :ok | {:error, term()}
  def enable_mouse_mode do
    case System.cmd("tmux", ["set", "-g", "mouse", "on"]) do
      {_output, 0} -> :ok
      {error, _code} -> {:error, error}
    end
  end

  @doc """
  Kill a tmux pane by ID.

  Returns :ok on success, even if the pane doesn't exist (idempotent).
  """
  @spec kill_pane(pane_id :: String.t()) :: :ok | {:error, term()}
  def kill_pane(pane_id) do
    case System.cmd("tmux", ["kill-pane", "-t", pane_id]) do
      {_output, 0} ->
        :ok

      {error, _code} when is_binary(error) ->
        if String.contains?(error, "can't find pane") do
          :ok
        else
          {:error, error}
        end

      {error, _code} ->
        {:error, error}
    end
  end

  @doc """
  List panes in a tmux window with a format string.

  Returns {:ok, output} on success, {:error, reason} on failure.
  """
  @spec list_panes(target :: String.t(), format :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def list_panes(target, format) do
    case System.cmd("tmux", ["list-panes", "-t", target, "-F", format]) do
      {output, 0} -> {:ok, output}
      {error, _code} -> {:error, error}
    end
  end

  @doc """
  Get a property from a tmux pane using display-message.

  Returns {:ok, value} on success, {:error, reason} on failure.
  """
  @spec get_pane_property(pane_id :: String.t(), property :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def get_pane_property(pane_id, property) do
    case System.cmd("tmux", ["display-message", "-t", pane_id, "-p", property]) do
      {output, 0} -> {:ok, String.trim(output)}
      {error, _code} -> {:error, error}
    end
  end

  @doc """
  Join a pane from a source window into the current window.

  This moves the first pane from the source window to be displayed in the current window.
  The original pane remains active so the TUI stays responsive.

  IMPORTANT: If the source window has only one pane, this will close that window.
  Ensure source window has at least 2 panes to keep it alive.

  Returns {:ok, pane_id} of the joined pane on success, {:error, reason} on failure.
  """
  @spec join_pane(source_window :: String.t(), opts :: keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def join_pane(source_window, opts \\ []) do
    direction = Keyword.get(opts, :direction, "-v")
    size = Keyword.get(opts, :size, "50%")

    with {:ok, session} <- get_current_session(),
         {current_pane_id, 0} <- System.cmd("tmux", ["display-message", "-p", "\#{pane_id}"]),
         current_pane_id = String.trim(current_pane_id),
         {window_id, 0} <- System.cmd("tmux", ["display-message", "-p", "\#{window_id}"]),
         window_id = String.trim(window_id),
         # Get panes before join
         {:ok, before_panes} <- list_panes(window_id, "\#{pane_id}"),
         before_set = before_panes |> String.trim() |> String.split("\n") |> MapSet.new(),
         # Perform the join
         {_output, 0} <-
           System.cmd("tmux", [
             "join-pane",
             "-s",
             "#{session}:#{source_window}.0",
             "-t",
             current_pane_id,
             direction,
             "-l",
             size
           ]),
         # Get panes after join
         {:ok, after_panes} <- list_panes(window_id, "\#{pane_id}"),
         after_set = after_panes |> String.trim() |> String.split("\n") |> MapSet.new(),
         # Find the new pane by diffing
         new_panes = MapSet.difference(after_set, before_set) |> MapSet.to_list(),
         [joined_pane_id] <- new_panes,
         # Keep focus on original pane so TUI stays responsive
         {_output, 0} <- System.cmd("tmux", ["select-pane", "-t", current_pane_id]) do
      Logger.info("Joined pane #{joined_pane_id} from window #{source_window}")
      {:ok, joined_pane_id}
    else
      [] -> {:error, "Could not identify joined pane"}
      [_ | _] = multiple -> {:error, "Multiple new panes detected: #{inspect(multiple)}"}
      {error, _code} when is_binary(error) -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Break a pane out into its own window.

  If window_name is provided, the new window will be renamed to that name.

  Returns :ok on success, {:error, reason} on failure.
  """
  @spec break_pane(pane_id :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
  def break_pane(pane_id, opts \\ []) do
    window_name = Keyword.get(opts, :window_name)

    # Break pane to its own window (let tmux create a new window)
    # -s specifies source pane, -t specifies destination window
    case System.cmd("tmux", ["break-pane", "-d", "-P", "-F", "\#{window_id}", "-s", pane_id]) do
      {window_id, 0} when is_binary(window_id) ->
        maybe_rename_broken_window(String.trim(window_id), window_name)

      {error, code} ->
        Logger.warning("break_pane failed: #{inspect(error)} (exit code: #{code})")
        {:error, error}
    end
  end

  defp maybe_rename_broken_window(_window_id, nil), do: :ok

  defp maybe_rename_broken_window(window_id, window_name) do
    case System.cmd("tmux", ["rename-window", "-t", window_id, window_name]) do
      {_output, 0} ->
        Logger.info("Broke pane to window #{window_id} and renamed to #{window_name}")
        :ok

      {error, code} ->
        Logger.warning("rename-window failed: #{inspect(error)} (exit code: #{code})")
        {:error, error}
    end
  end
end
