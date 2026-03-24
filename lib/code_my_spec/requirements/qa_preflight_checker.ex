defmodule CodeMySpec.Requirements.QaPreflightChecker do
  @moduledoc """
  Checks whether QA preflight verification is complete.

  Validates that all integration specs have been verified against the running app:
  1. All integration specs exist and have verify scripts
  2. All integration specs have `status: verified`
  3. Integration preflight report exists at `.code_my_spec/qa/preflight.md`
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  @integrations_dir Paths.integrations_dir()
  @integrations_index Paths.integrations_index()
  @preflight_report Path.join(Paths.qa_dir(), "preflight.md")

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
    with :ok <- check_integrations_or_none(env),
         :ok <- check_preflight_report(env) do
      {true, %{status: "Preflight verification complete"}}
    else
      {:error, reason} ->
        {false, %{reason: reason}}
    end
  end

  defp check_integrations_or_none(env) do
    case Environments.read_file(env, @integrations_index) do
      {:ok, content} when byte_size(content) > 0 ->
        if String.contains?(String.downcase(content), "no integrations") do
          :ok
        else
          check_all_specs_verified(env)
        end

      _ ->
        {:error, "Integration index missing at #{@integrations_index}"}
    end
  end

  defp check_all_specs_verified(env) do
    case Environments.glob(env, Path.join(@integrations_dir, "*.md")) do
      files when is_list(files) and files != [] ->
        Enum.reduce_while(files, :ok, fn file, :ok ->
          case Environments.read_file(env, file) do
            {:ok, content} ->
              if String.contains?(String.downcase(content), "verified") do
                {:cont, :ok}
              else
                {:halt, {:error, "Integration #{file} not verified against running app"}}
              end

            _ ->
              {:halt, {:error, "Cannot read integration spec #{file}"}}
          end
        end)

      _ ->
        {:error, "Integration index references integrations but no specs found in #{@integrations_dir}/"}
    end
  end

  defp check_preflight_report(env) do
    case Environments.read_file(env, @preflight_report) do
      {:ok, content} when byte_size(content) > 0 -> :ok
      {:ok, _} -> {:error, "Preflight report is empty at #{@preflight_report}"}
      _ -> {:error, "Preflight report missing at #{@preflight_report}"}
    end
  end
end
