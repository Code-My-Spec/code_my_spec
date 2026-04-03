defmodule CodeMySpec.RequirementsFixtures do
  @moduledoc """
  Test helpers for seeding File records that drive computed requirements.

  Requirements are no longer persisted — they're computed from Files + Problems.
  This fixture creates the File records that the RequirementCalculator checks.
  """

  alias CodeMySpec.Files

  @requirement_to_role %{
    "spec_file" => :spec,
    "spec_valid" => :spec,
    "design_file" => :spec,
    "implementation_file" => :implementation,
    "test_file" => :test,
    "test_spec_alignment" => :test,
    "review_file" => :review,
    "review_valid" => :review,
    "json_file" => :json
  }

  @doc """
  Seed a File record that satisfies (or not) a named requirement.

  Maps requirement names to file roles and creates appropriate File records.
  For "satisfied: true", creates a file with valid: true.
  For "satisfied: false", either skips file creation (file-existence reqs)
  or creates an invalid file (validation reqs).
  """
  def requirement_fixture(scope, component, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: "design_file",
          artifact_type: :specification,
          description: "Component design documentation exists",
          satisfied: false,
          details: %{}
        },
        attrs
      )

    role = Map.get(@requirement_to_role, attrs.name)
    satisfied = attrs.satisfied

    cond do
      attrs.name == "tests_passing" and not satisfied ->
        # Create test failure problems so RequirementCalculator sees failures
        seed_test_failures(scope, component)
        attrs

      attrs.name == "tests_passing" ->
        # Satisfied = no problems needed (default state)
        attrs

      is_nil(role) ->
        # Unknown requirement — return attrs as-is for backwards compat
        attrs

      not satisfied and is_existence_check?(attrs.name) ->
        # Don't create file — absence means unsatisfied
        attrs

      true ->
        path = file_path_for(scope, component, role)

        if path do
          valid = if is_validity_check?(attrs.name), do: satisfied, else: satisfied
          seed_component_file(scope, component, role, path, valid)
        end

        attrs
    end
  end

  @doc """
  Generate requirement attrs for testing.
  """
  def requirement_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        name: "design_file",
        artifact_type: :specification,
        description: "Component design documentation exists",
        satisfied: false,
        details: %{}
      },
      attrs
    )
  end

  @doc """
  Generate multiple requirements for a component.
  """
  def requirements_fixture(scope, component, count \\ 3) do
    Enum.map(1..count, fn i ->
      requirement_fixture(scope, component, %{
        name: "requirement_#{i}",
        description: "Test requirement #{i}"
      })
    end)
  end

  # -- Private --

  defp seed_test_failures(scope, component) do
    files = CodeMySpec.Utils.component_files(component, scope.active_project)
    test_path = Map.get(files, :test_file, "test/unknown_test.exs")

    {:ok, _} =
      CodeMySpec.Problems.create_problems(scope, [
        %{
          severity: :error,
          source_type: :test,
          source: "exunit",
          file_path: test_path,
          message: "test failed: expected true, got false",
          category: "test_failure",
          component_id: component.id
        }
      ])
  end

  defp is_existence_check?(name), do: name in ~w(spec_file implementation_file test_file review_file json_file design_file)
  defp is_validity_check?(name), do: name in ~w(spec_valid review_valid test_spec_alignment)

  defp seed_component_file(scope, component, role, path, valid) do
    {_count, [file]} =
      Files.upsert_files(scope, [
        %{
          path: path,
          role: role,
          mtime: DateTime.utc_now() |> DateTime.truncate(:second),
          size: 100,
          component_id: component.id
        }
      ])

    if valid != nil do
      {:ok, _file} = Files.mark_validated(file, valid)
    end

    file
  end

  defp file_path_for(scope, component, role) do
    files = CodeMySpec.Utils.component_files(component, scope.active_project)

    case role do
      :spec -> Map.get(files, :spec_file)
      :implementation -> Map.get(files, :code_file)
      :test -> Map.get(files, :test_file)
      :review -> Map.get(files, :review_file)
      :json -> Map.get(files, :json_file)
    end
  end
end
