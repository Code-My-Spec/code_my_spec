defmodule CodeMySpec.Requirements.AcceptedIssuesChecker do
  @moduledoc """
  Checks whether all medium+ accepted QA issues have been resolved.

  Scans `.code_my_spec/issues/accepted/` for issue files. An issue is blocking
  if its severity is critical, high, or medium and it has no `## Resolution` section.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.{Environments, Paths}
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  @blocking_severities ~w(critical high medium)

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
    files = Environments.glob(env, "#{Paths.issues_accepted_dir()}/*.md") || []

    blocking =
      files
      |> Enum.filter(fn path ->
        case Environments.read_file(env, path) do
          {:ok, content} ->
            {severity, has_resolution} = parse_issue_metadata(content)
            severity in @blocking_severities and not has_resolution

          _ ->
            false
        end
      end)

    {satisfied, details} =
      case blocking do
        [] ->
          {true, %{status: "No unresolved medium+ issues"}}

        files ->
          {false,
           %{
             reason: "#{length(files)} unresolved medium+ issue(s) in accepted/",
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

  @doc false
  def parse_issue_metadata(content) when is_binary(content) do
    severity =
      case Regex.run(~r/^## Severity\s*\n\s*(\w+)/m, content) do
        [_, sev] -> String.downcase(sev)
        _ -> "unknown"
      end

    has_resolution = Regex.match?(~r/^## Resolution/m, content)

    {severity, has_resolution}
  end
end
