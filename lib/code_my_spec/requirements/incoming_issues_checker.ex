defmodule CodeMySpec.Requirements.IncomingIssuesChecker do
  @moduledoc """
  Checks whether incoming QA issues at medium+ severity have been triaged.

  Satisfied when `.code_my_spec/issues/incoming/` contains no `.md` files
  with severity of medium, high, or critical. Low and info issues are
  ignored — they don't block the workflow.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.{Environments, Paths}
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  @triage_severities ~w(critical high medium)

  def check(
        %Scope{} = scope,
        %RequirementDefinition{
          name: name,
          artifact_type: artifact_type,
          description: description,
          checker: checker,
          satisfied_by: satisfied_by
        },
        _entity,
        _opts \\ []
      ) do
    env = scope.environment
    all_files = Environments.glob(env, "#{Paths.issues_incoming_dir()}/*.md") || []

    triageable =
      Enum.filter(all_files, fn path ->
        case Environments.read_file(env, path) do
          {:ok, content} -> parse_severity(content) in @triage_severities
          _ -> false
        end
      end)

    {satisfied, details} =
      case triageable do
        [] ->
          {true, %{status: "No untriaged issues at medium+ severity"}}

        files ->
          {false,
           %{
             reason: "#{length(files)} untriaged issue(s) at medium+ severity in incoming/",
             files: Enum.map(files, &Path.basename/1)
           }}
      end

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

  defp parse_severity(content) do
    case Regex.run(~r/^## Severity\s*\n\s*(\w+)/m, content) do
      [_, sev] -> String.downcase(sev)
      _ -> "unknown"
    end
  end
end
