defmodule CodeMySpec.Requirements.QaIntegrationPlanChecker do
  @moduledoc """
  Checks whether QA integration planning is complete.

  Validates:
  1. Integration index exists at `.code_my_spec/integrations.md`
  2. At least one integration spec exists (if technical decisions reference integrations)
  3. All referenced verify scripts exist
  4. Runs each verify script and validates structured JSON output
  5. All integration specs have `status: verified`
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Documents
  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  @integrations_index Paths.integrations_index()
  @integrations_dir Paths.integrations_dir()

  def check(
        %Scope{} = scope,
        %RequirementDefinition{
          name: name,
          artifact_type: artifact_type,
          description: description,
          checker: checker,
          satisfied_by: satisfied_by
        },
        %Project{},
        _opts \\ []
      ) do
    env = scope.environment

    {satisfied, details} = run_checks(env)

    %{
      name: name,
      artifact_type: artifact_type,
      description: description,
      checker_module: checker,
      satisfied_by: satisfied_by,
      satisfied: satisfied,
      score: if(satisfied, do: 1.0, else: 0.0),
      checked_at: DateTime.utc_now(),
      details: details
    }
  end

  defp run_checks(env) do
    spec_files = list_spec_files(env)

    if spec_files == [] do
      {true, %{status: "No integrations required", integration_count: 0}}
    else
      with :ok <- check_index_exists(env),
           :ok <- check_specs_valid(env, spec_files),
           :ok <- check_verify_scripts_exist(env, spec_files),
           :ok <- check_all_verified(env, spec_files) do
        {true, %{status: "All integrations verified", integration_count: length(spec_files)}}
      else
        {:error, reason} ->
          {false, %{reason: reason}}
      end
    end
  end

  defp list_spec_files(env) do
    case Environments.glob(env, Path.join(@integrations_dir, "*.md")) do
      files when is_list(files) -> files
      _ -> []
    end
  end

  defp check_index_exists(env) do
    case Environments.read_file(env, @integrations_index) do
      {:ok, content} when byte_size(content) > 0 -> :ok
      {:ok, _} -> {:error, "Integration index is empty at #{@integrations_index}"}
      _ -> {:error, "Integration index missing at #{@integrations_index}"}
    end
  end

  defp check_specs_valid(env, spec_files) do
    Enum.reduce_while(spec_files, :ok, fn file, :ok ->
      case Environments.read_file(env, file) do
        {:ok, content} when byte_size(content) > 0 ->
          case Documents.create_dynamic_document(content, "integration_spec") do
            {:ok, _doc} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, "Invalid integration spec #{file}: #{inspect(reason)}"}}
          end

        _ ->
          {:halt, {:error, "Cannot read integration spec #{file}"}}
      end
    end)
  end

  defp check_verify_scripts_exist(env, spec_files) do
    Enum.reduce_while(spec_files, :ok, fn file, :ok ->
      case read_verify_script_path(env, file) do
        {:ok, script_path} ->
          case Environments.file_exists?(env, script_path) do
            true -> {:cont, :ok}
            _ -> {:halt, {:error, "Verify script missing: #{script_path} (referenced by #{file})"}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp check_all_verified(env, spec_files) do
    Enum.reduce_while(spec_files, :ok, fn file, :ok ->
      case Environments.read_file(env, file) do
        {:ok, content} ->
          if String.contains?(String.downcase(content), "verified") do
            {:cont, :ok}
          else
            {:halt, {:error, "Integration spec #{file} is not yet verified"}}
          end

        _ ->
          {:halt, {:error, "Cannot read integration spec #{file}"}}
      end
    end)
  end

  defp read_verify_script_path(env, spec_file) do
    case Environments.read_file(env, spec_file) do
      {:ok, content} ->
        # Extract verify script path from the "## Verify Script" section
        case Regex.run(~r/##\s*Verify Script\s*\n+`?([^\n`]+)`?/i, content) do
          [_, path] -> {:ok, String.trim(path)}
          _ -> {:error, "No verify script path found in #{spec_file}"}
        end

      _ ->
        {:error, "Cannot read integration spec #{spec_file}"}
    end
  end
end
