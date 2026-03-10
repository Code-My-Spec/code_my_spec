defmodule CodeMySpec.ContentSync.FileWatcher.Impl do
  @moduledoc """
  Pure implementation logic for file watching.

  Contains only pure functions with zero side effects - all business logic
  for debouncing, event filtering, and state management without any GenServer
  or process-related code.

  This module is 100% unit testable without needing to start processes.
  """

  alias CodeMySpec.Accounts.{Account, AccountsRepository}
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Users.{Scope, User}
  alias CodeMySpec.Repo

  defstruct [:scope, :watched_directory, :debounce_timer, :debounce_ms, :sync_fn]

  @type t :: %__MODULE__{
          scope: Scope.t(),
          watched_directory: String.t(),
          debounce_timer: reference() | nil,
          debounce_ms: non_neg_integer(),
          sync_fn: (Scope.t(), String.t() -> {:ok, map()} | {:error, term()})
        }

  @default_debounce_ms 1000

  # ============================================================================
  # Configuration Building
  # ============================================================================

  @doc """
  Builds configuration from options and application environment.

  Options take precedence over application config. Returns {:ok, config_map}
  or {:error, reason} if required config is missing.

  ## Options

    - `:directory` - Directory to watch (required)
    - `:scope` - Scope struct with account/project (required)
    - `:debounce_ms` - Debounce delay in milliseconds (default: 1000)
    - `:sync_fn` - Function to call for sync (default: ContentSync.sync_directory_to_content_and_content_admin/2)
  """
  @spec build_config(keyword()) :: {:ok, map()} | {:error, atom()}
  def build_config(opts) do
    with {:ok, directory} <- get_directory(opts),
         {:ok, scope} <- get_scope(opts) do
      config = %{
        directory: directory,
        scope: scope,
        debounce_ms: opts[:debounce_ms] || @default_debounce_ms,
        sync_fn:
          opts[:sync_fn] ||
            (&CodeMySpec.ContentSync.sync_directory_to_content_admin/2)
      }

      {:ok, config}
    end
  end

  @spec get_directory(keyword()) :: {:ok, String.t()} | {:error, :missing_directory_config}
  defp get_directory(opts) do
    case opts[:directory] || Application.get_env(:code_my_spec, :content_watch_directory) do
      nil -> {:error, :missing_directory_config}
      "" -> {:error, :missing_directory_config}
      directory when is_binary(directory) -> {:ok, directory}
    end
  end

  @spec get_scope(keyword()) ::
          {:ok, Scope.t()}
          | {:error,
             :missing_scope_config | :account_not_found | :project_not_found | :user_not_found}
  defp get_scope(opts) do
    case opts[:scope] do
      %Scope{} = scope ->
        {:ok, scope}

      nil ->
        load_scope_from_config()
    end
  end

  @spec load_scope_from_config() ::
          {:ok, Scope.t()}
          | {:error,
             :missing_scope_config | :account_not_found | :project_not_found | :user_not_found}
  defp load_scope_from_config do
    case Application.get_env(:code_my_spec, :content_watch_scope) do
      nil ->
        {:error, :missing_scope_config}

      %{user_id: user_id, account_id: account_id, project_id: project_id}
      when not is_nil(user_id) and not is_nil(account_id) and not is_nil(project_id) ->
        with {:ok, user} <- load_user(user_id),
             {:ok, account} <- load_account(account_id),
             {:ok, project} <- load_project(project_id) do
          scope = %Scope{
            user: user,
            active_account: account,
            active_account_id: account.id,
            active_project: project,
            active_project_id: project.id
          }

          {:ok, scope}
        end

      _ ->
        {:error, :missing_scope_config}
    end
  end

  @spec load_account(Ecto.UUID.t()) :: {:ok, Account.t()} | {:error, :account_not_found}
  defp load_account(account_id) do
    case AccountsRepository.get_account(account_id) do
      nil -> {:error, :account_not_found}
      account -> {:ok, account}
    end
  end

  @spec load_project(Ecto.UUID.t()) :: {:ok, Project.t()} | {:error, :project_not_found}
  defp load_project(project_id) do
    case Repo.get(Project, project_id) do
      nil -> {:error, :project_not_found}
      project -> {:ok, project}
    end
  end

  @spec load_user(integer()) :: {:ok, User.t()} | {:error, :user_not_found}
  defp load_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  # ============================================================================
  # Validation
  # ============================================================================

  @doc """
  Validates that a directory exists and is actually a directory.

  Returns :ok if valid, {:error, :invalid_directory} otherwise.
  """
  @spec validate_directory(String.t()) :: :ok | {:error, :invalid_directory}
  def validate_directory(directory) do
    cond do
      not File.exists?(directory) ->
        {:error, :invalid_directory}

      not File.dir?(directory) ->
        {:error, :invalid_directory}

      true ->
        :ok
    end
  end

  @doc """
  Validates complete configuration including directory validation.
  """
  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(%{directory: directory}) do
    validate_directory(directory)
  end

  # ============================================================================
  # State Initialization
  # ============================================================================

  @doc """
  Creates initial state from validated configuration.
  """
  @spec new_state(map()) :: t()
  def new_state(%{directory: directory, scope: scope, debounce_ms: debounce_ms, sync_fn: sync_fn}) do
    %__MODULE__{
      scope: scope,
      watched_directory: directory,
      debounce_timer: nil,
      debounce_ms: debounce_ms,
      sync_fn: sync_fn
    }
  end

  # ============================================================================
  # Event Filtering
  # ============================================================================

  @doc """
  Checks if an event list contains relevant file events.

  Returns true if events contain :modified, :created, or :removed.
  Returns false for empty lists or other event types.

  ## Examples

      iex> FileWatcher.Impl.relevant_event?([:modified])
      true

      iex> FileWatcher.Impl.relevant_event?([:created, :modified])
      true

      iex> FileWatcher.Impl.relevant_event?([])
      false

      iex> FileWatcher.Impl.relevant_event?([:other])
      false
  """
  @spec relevant_event?(list()) :: boolean()
  def relevant_event?(events) when is_list(events) do
    Enum.any?(events, fn event ->
      event in [:modified, :created, :removed]
    end)
  end

  def relevant_event?(_), do: false

  # ============================================================================
  # State Transformations
  # ============================================================================

  @doc """
  Handles a file event and returns the action to take.

  Returns:
    - `{:schedule_sync, new_timer_ref, new_state}` - Schedule sync with new timer
    - `{:noreply, new_state}` - No action needed

  This is a pure function - it does NOT perform the actual timer scheduling,
  it just returns what should be done. The caller (GenServer) performs the side effect.
  """
  @spec handle_file_event(t(), String.t(), list()) ::
          {:schedule_sync, non_neg_integer(), t()} | {:noreply, t()}
  def handle_file_event(state, _path, events) do
    if relevant_event?(events) do
      # Return the action and updated state (without timer ref yet)
      # The GenServer will create the actual timer and update state with it
      {:schedule_sync, state.debounce_ms, %{state | debounce_timer: nil}}
    else
      {:noreply, state}
    end
  end

  @doc """
  Updates state with a new timer reference after scheduling.
  """
  @spec update_timer(t(), reference()) :: t()
  def update_timer(state, timer_ref) do
    %{state | debounce_timer: timer_ref}
  end

  @doc """
  Handles a sync trigger and returns sync arguments.

  Returns `{scope, sync_fn, new_state}` where scope and directory should be passed to sync_fn
  and new_state has the timer cleared.
  """
  @spec handle_sync_trigger(t()) :: {Scope.t(), (Scope.t(), String.t() -> any()), t()}
  def handle_sync_trigger(state) do
    new_state = %{state | debounce_timer: nil}
    {state.scope, state.sync_fn, new_state}
  end

  @doc """
  Clears the timer reference from state.

  Note: This does NOT cancel the actual timer process - that's a side effect
  the caller must perform. This just updates the state.
  """
  @spec clear_timer(t()) :: t()
  def clear_timer(state) do
    %{state | debounce_timer: nil}
  end
end
