defmodule CodeMySpec.ContentSync do
  @moduledoc """
  Orchestrates content sync pipelines in two different contexts:

  1. **Server-Side (CodeMySpec SaaS)**: Syncs from Git -> ContentAdmin for validation only
  2. **Client-Side (Client Appliances)**: Syncs from Git -> Content with full schema

  Both use the same parsing/processing logic but write to different schemas.
  Git repository is always the source of truth.
  """

  alias CodeMySpec.{ContentAdmin, Git, Projects}
  alias CodeMySpec.ContentSync.Sync
  alias CodeMySpec.Users.Scope

  @type sync_result :: %{
          total_files: integer(),
          successful: integer(),
          errors: integer(),
          duration_ms: integer(),
          content_synced: integer()
        }

  @type push_result :: %{
          synced_content_count: integer(),
          client_response: map()
        }

  # NOTE: Old sync_from_git and list_content_errors functions removed
  # These were for the old multi-tenant Content system.
  # Content is now single-tenant (no Scope), so these functions don't apply.
  # If you need to sync to Content, use Sync.process_directory/1 directly
  # and then call Content repository functions (without scope).

  @doc """
  Syncs content from Git repository to ContentAdmin for validation only.

  This is the server-side sync that validates content and shows parse status
  to developers. Does not include full content schema - just validation results.

  ## Parameters

    - `scope` - User scope containing account and project information

  ## Returns

    - `{:ok, sync_result}` - Successful sync with statistics
    - `{:error, :no_active_project}` - No active project in scope
    - `{:error, :project_not_found}` - Project doesn't exist or scope doesn't have access
    - `{:error, :no_docs_repo}` - Project has no docs_repo configured
    - `{:error, reason}` - Git clone failed or sync operation failed

  ## Process

  1. Validates scope has an active project
  2. Loads project to retrieve docs_repo URL
  3. Creates temporary directory using Briefly
  4. Clones repository to temporary directory
  5. Syncs content to ContentAdmin (validation only)
  6. Returns sync result (temp directory cleaned up automatically)

  ## Examples

      iex> sync_to_content_admin(scope)
      {:ok, %{total_files: 10, successful: 9, errors: 1, duration_ms: 1234}}
  """
  @spec sync_to_content_admin(Scope.t()) :: {:ok, sync_result()} | {:error, term()}
  def sync_to_content_admin(%Scope{active_project_id: nil}), do: {:error, :no_active_project}

  def sync_to_content_admin(%Scope{} = scope) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, project} <- load_project(scope),
         {:ok, repo_url} <- extract_docs_repo(project),
         {:ok, temp_path} <- create_temp_directory(),
         {:ok, cloned_path} <- clone_repository(scope, repo_url, temp_path),
         content_dir = Path.join(cloned_path, "content"),
         {:ok, attrs_list} <- Sync.process_directory(content_dir),
         {:ok, validated_attrs_list} <- validate_attrs_against_content_schema(attrs_list),
         {:ok, content_admin_list} <-
           persist_validated_content_to_admin(scope, validated_attrs_list) do
      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      sync_result = %{
        total_files: length(content_admin_list),
        successful: Enum.count(content_admin_list, &(&1.parse_status == :success)),
        errors: Enum.count(content_admin_list, &(&1.parse_status == :error)),
        duration_ms: duration_ms,
        content_synced: 0
      }

      # Broadcast sync completed
      broadcast_sync_completed(scope, sync_result)

      {:ok, sync_result}
    end
  end

  def sync_directory_to_content_and_content_admin(%Scope{} = scope, content_dir) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, attrs_list} <- Sync.process_directory(content_dir),
         {:ok, validated_attrs_list} <- validate_attrs_against_content_schema(attrs_list),
         {:ok, content_admin_list} <-
           persist_validated_content_to_admin(scope, validated_attrs_list),
         {:ok, content_list} <- sync_to_content(validated_attrs_list) do
      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      sync_result = %{
        total_files: length(content_admin_list),
        successful: Enum.count(content_admin_list, &(&1.parse_status == :success)),
        errors: Enum.count(content_admin_list, &(&1.parse_status == :error)),
        duration_ms: duration_ms,
        content_synced: length(content_list)
      }

      # Broadcast sync completed
      broadcast_sync_completed(scope, sync_result)

      {:ok, sync_result}
    end
  end

  @doc """
  Lists all ContentAdmin records with error parse status for the given scope.

  ## Parameters

    - `scope` - User scope containing account and project information

  ## Returns

  List of ContentAdmin records where `parse_status` is `:error`

  ## Examples

      iex> list_content_admin_errors(scope)
      [%ContentAdmin{parse_status: :error, parse_errors: %{...}}, ...]
  """
  @spec list_content_admin_errors(Scope.t()) :: [ContentAdmin.ContentAdmin.t()]
  def list_content_admin_errors(%Scope{} = scope) do
    ContentAdmin.list_by_parse_status(scope, :error)
  end

  @doc """
  Pushes content from server to client appliance.

  Re-syncs content from Git (Git is source of truth), validates it,
  and POSTs to client's /api/content/sync endpoint with authentication.

  ## Parameters

    - `scope` - User scope containing account and project information
    - `client_api_url` - Client appliance API URL
    - `deploy_key` - Authentication key for client API

  ## Returns

    - `{:ok, push_result}` - Successful push with statistics
    - `{:error, :no_active_project}` - No active project in scope
    - `{:error, :has_validation_errors}` - ContentAdmin has parse errors, must fix first
    - `{:error, :project_not_found}` - Project doesn't exist or scope doesn't have access
    - `{:error, :no_docs_repo}` - Project has no docs_repo configured
    - `{:error, :no_client_config}` - Missing client_api_url or deploy_key
    - `{:error, reason}` - Git clone failed or HTTP request failed

  ## Process

  1. Verifies ContentAdmin has no validation errors
  2. Loads project config (client_api_url, deploy_key)
  3. Clones Git repo to temp directory (Git is source of truth)
  4. Parses all content files with full Content schema
  5. Validates using Content.changeset
  6. Builds push payload with tags
  7. POSTs to client API with authentication
  8. Returns push result

  ## Examples

      iex> push_to_client(scope, "https://client.example.com", "deploy_key_123")
      {:ok, %{synced_content_count: 10, client_response: %{...}}}
  """
  @spec push_to_client(Scope.t(), String.t() | nil, String.t() | nil) ::
          {:ok, push_result()} | {:error, term()}
  def push_to_client(%Scope{active_project_id: nil}), do: {:error, :no_active_project}

  def push_to_client(%Scope{} = scope) do
    push_to_client(scope, nil, nil)
  end

  def push_to_client(%Scope{active_project_id: nil}, _client_api_url, _deploy_key),
    do: {:error, :no_active_project}

  def push_to_client(%Scope{} = scope, client_api_url, deploy_key) do
    with :ok <- verify_no_validation_errors(scope),
         {:ok, project} <- load_project(scope),
         {:ok, client_api_url} <- get_client_api_url(project, client_api_url),
         {:ok, deploy_key} <- get_deploy_key(project, deploy_key),
         {:ok, repo_url} <- extract_docs_repo(project),
         {:ok, temp_path} <- create_temp_directory(),
         {:ok, cloned_path} <- clone_repository(scope, repo_url, temp_path) do
      content_dir = Path.join(cloned_path, "content")

      # Use agnostic Sync.process_directory to parse content from Git
      case Sync.process_directory(content_dir) do
        {:ok, attrs_list} ->
          # Filter to only successfully parsed content
          valid_content =
            attrs_list
            |> Enum.filter(&(&1.parse_status == :success))
            |> Enum.map(fn attrs ->
              # Content schema doesn't have parse_status/parse_errors or raw_content
              # Only include Content fields
              Map.take(attrs, [
                :slug,
                :title,
                :content_type,
                :processed_content,
                :protected,
                :publish_at,
                :expires_at,
                :meta_title,
                :meta_description,
                :og_image,
                :og_title,
                :og_description,
                :metadata
              ])
            end)

          # Build push payload
          payload = %{
            content: valid_content,
            synced_at: DateTime.utc_now()
          }

          # POST to client API
          case post_to_client_api(client_api_url, deploy_key, payload) do
            {:ok, response} ->
              {:ok,
               %{
                 synced_content_count: length(valid_content),
                 client_response: response
               }}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def push_to_client(_scope, _client_api_url, _deploy_key), do: {:error, :invalid_parameters}

  # ============================================================================
  # Private Functions - Validation
  # ============================================================================

  @spec verify_no_validation_errors(Scope.t()) :: :ok | {:error, :has_validation_errors}
  defp verify_no_validation_errors(%Scope{} = scope) do
    case ContentAdmin.count_by_parse_status(scope) do
      %{error: 0} -> :ok
      %{error: _count} -> {:error, :has_validation_errors}
    end
  end

  @spec validate_attrs_against_content_schema([map()]) :: {:ok, [map()]}
  defp validate_attrs_against_content_schema(attrs_list) do
    {:ok, Enum.map(attrs_list, &validate_single_attrs/1)}
  end

  @content_schema_fields [
    :slug, :title, :content_type, :processed_content, :protected,
    :publish_at, :expires_at, :meta_title, :meta_description,
    :og_image, :og_title, :og_description, :metadata
  ]

  defp validate_single_attrs(attrs) do
    content_attrs = Map.take(attrs, @content_schema_fields)

    changeset =
      CodeMySpec.Content.Content.changeset(%CodeMySpec.Content.Content{}, content_attrs)

    if changeset.valid? do
      attrs
    else
      content_errors = format_changeset_errors(changeset)

      %{
        attrs
        | parse_status: :error,
          parse_errors:
            Map.merge(attrs[:parse_errors] || %{}, %{content_validation: content_errors})
      }
    end
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  @spec persist_validated_content_to_admin(Scope.t(), [map()]) ::
          {:ok, [ContentAdmin.ContentAdmin.t()]} | {:error, term()}
  defp persist_validated_content_to_admin(%Scope{} = scope, validated_attrs_list) do
    CodeMySpec.Repo.transaction(fn ->
      # Delete existing ContentAdmin records for this project
      {:ok, _count} = ContentAdmin.delete_all_content(scope)

      # Add multi-tenant scoping to each attribute map
      admin_attrs_list =
        Enum.map(validated_attrs_list, fn attrs ->
          Map.merge(attrs, %{
            account_id: scope.active_account_id,
            project_id: scope.active_project_id
          })
        end)

      # Create ContentAdmin records
      case ContentAdmin.create_many(scope, admin_attrs_list) do
        {:ok, content_admin_list} ->
          content_admin_list

        {:error, reason} ->
          CodeMySpec.Repo.rollback(reason)
      end
    end)
  end

  # ============================================================================
  # Private Functions - Project and Repository Loading
  # ============================================================================

  @spec load_project(Scope.t()) :: {:ok, Projects.Project.t()} | {:error, :project_not_found}
  defp load_project(%Scope{} = scope) do
    case Projects.get_project(scope, scope.active_project_id) do
      {:ok, project} -> {:ok, project}
      {:error, :not_found} -> {:error, :project_not_found}
    end
  end

  @spec extract_docs_repo(Projects.Project.t()) ::
          {:ok, String.t()} | {:error, :no_docs_repo}
  defp extract_docs_repo(%{docs_repo: nil}), do: {:error, :no_docs_repo}
  defp extract_docs_repo(%{docs_repo: ""}), do: {:error, :no_docs_repo}
  defp extract_docs_repo(%{docs_repo: repo_url}), do: {:ok, repo_url}

  @spec get_client_api_url(Projects.Project.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :no_client_config}
  defp get_client_api_url(_project, client_api_url) when is_binary(client_api_url),
    do: {:ok, client_api_url}

  defp get_client_api_url(%{client_api_url: nil}, nil), do: {:error, :no_client_config}
  defp get_client_api_url(%{client_api_url: ""}, nil), do: {:error, :no_client_config}
  defp get_client_api_url(%{client_api_url: url}, nil), do: {:ok, url}

  @spec get_deploy_key(Projects.Project.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :no_client_config}
  defp get_deploy_key(_project, deploy_key) when is_binary(deploy_key), do: {:ok, deploy_key}
  defp get_deploy_key(%{deploy_key: nil}, nil), do: {:error, :no_client_config}
  defp get_deploy_key(%{deploy_key: ""}, nil), do: {:error, :no_client_config}
  defp get_deploy_key(%{deploy_key: key}, nil), do: {:ok, key}

  # ============================================================================
  # Private Functions - Git Operations
  # ============================================================================

  @spec create_temp_directory() :: {:ok, String.t()} | {:error, term()}
  defp create_temp_directory do
    case Briefly.create(directory: true) do
      {:ok, path} -> {:ok, path}
      error -> error
    end
  end

  @spec clone_repository(Scope.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp clone_repository(%Scope{} = scope, repo_url, temp_path) do
    Git.clone(scope, repo_url, temp_path)
  end

  # ============================================================================
  # Private Functions - HTTP Client Operations
  # ============================================================================

  @spec post_to_client_api(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  defp post_to_client_api(client_api_url, deploy_key, payload) do
    url = URI.parse(client_api_url) |> URI.merge("/api/content/sync") |> URI.to_string()

    case Req.post(url,
           json: payload,
           headers: [
             {"Authorization", "Bearer #{deploy_key}"}
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status_code, body: response_body}} ->
        {:error, {:http_error, status_code, response_body}}

      {:error, exception} ->
        {:error, {:http_request_failed, Exception.message(exception)}}
    end
  end

  # ============================================================================
  # Private Functions - Broadcasting
  # ============================================================================

  @spec broadcast_sync_completed(Scope.t(), sync_result()) :: :ok | {:error, term()}
  defp broadcast_sync_completed(%Scope{} = scope, sync_result) do
    Phoenix.PubSub.broadcast(
      CodeMySpec.PubSub,
      content_admin_topic(scope),
      {:sync_completed, sync_result}
    )
  end

  @spec content_admin_topic(Scope.t()) :: String.t()
  defp content_admin_topic(%Scope{} = scope) do
    "account:#{scope.active_account_id}:project:#{scope.active_project_id}:content_admin"
  end

  # ============================================================================
  # Private Functions - Content Sync
  # ============================================================================

  @spec sync_to_content([map()]) :: {:ok, [CodeMySpec.Content.Content.t()]} | {:error, term()}
  defp sync_to_content(attrs_list) do
    require Logger

    # Filter to only successfully parsed content
    valid_content =
      attrs_list
      |> Enum.filter(&(&1.parse_status == :success))
      |> Enum.map(fn attrs ->
        # Extract only Content schema fields (no parse_status, parse_errors, raw_content)
        Map.take(attrs, [
          :slug,
          :title,
          :content_type,
          :processed_content,
          :protected,
          :publish_at,
          :expires_at,
          :meta_title,
          :meta_description,
          :og_image,
          :og_title,
          :og_description,
          :metadata
        ])
      end)

    Logger.info("Syncing #{length(valid_content)} valid content items to Content schema")

    case CodeMySpec.Content.sync_content(valid_content) do
      {:ok, content_list} ->
        Logger.info("Successfully synced #{length(content_list)} items to Content")
        {:ok, content_list}

      {:error, reason} ->
        Logger.error("Failed to sync to Content: #{inspect(reason)}")
        {:error, reason}
    end
  end

end
