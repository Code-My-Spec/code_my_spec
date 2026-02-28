defmodule CodeMySpec.Requirements.BddSpecPassingChecker do
  @moduledoc """
  Checks whether BDD specs pass for a story.
  """

  @behaviour CodeMySpec.Requirements.CheckerBehaviour

  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  def check(
        %Scope{} = scope,
        %RequirementDefinition{
          name: name,
          artifact_type: artifact_type,
          description: description,
          checker: checker,
          satisfied_by: satisfied_by
        },
        %Story{} = story,
        _opts \\ []
      ) do
    env = scope.environment
    specs = BddSpecs.list_specs_for_story(env, story.id)

    {satisfied, details} =
      if specs == [] do
        {false, %{reason: "No BDD spec files to run for story #{story.id}"}}
      else
        file_paths = Enum.map(specs, & &1.file_path)

        case BddSpecs.run_specs(file_paths, project_root: scope.cwd) do
          {:ok, [], 0} ->
            {true, %{spec_count: length(specs), all_passing: true}}

          {:ok, failures, _exit_code} ->
            {false,
             %{
               spec_count: length(specs),
               failure_count: length(failures),
               failures: Enum.map(failures, &deep_to_map/1)
             }}

          {:error, reason} ->
            {false, %{reason: "Failed to run specs: #{inspect(reason)}"}}
        end
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

  # Recursively converts structs to plain maps so Ecto can dump the :map field.
  defp deep_to_map(%_{} = struct), do: struct |> Map.from_struct() |> deep_to_map()
  defp deep_to_map(%{} = map), do: Map.new(map, fn {k, v} -> {k, deep_to_map(v)} end)
  defp deep_to_map(list) when is_list(list), do: Enum.map(list, &deep_to_map/1)
  defp deep_to_map(other), do: other
end
