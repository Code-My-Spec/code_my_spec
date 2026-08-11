defmodule CodeMySpec.BddSpecs.SpecProjectorTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.BddSpecs.{Spec, Scenario, Step, SpecProjector}
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.AcceptanceCriteria.Criterion

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp spec_fixture(overrides \\ %{}) do
    defaults = %{
      name: "User Authentication",
      file_path: "/path/to/spec/user_auth_spec.exs",
      description: "Authentication spec",
      story_number: 1,
      criterion_id: 10,
      tags: [:integration],
      scenarios: [
        %{
          name: "Successful login",
          given_steps: ["user exists with valid credentials"],
          when_steps: ["user submits login form"],
          then_steps: ["user is authenticated", "user is redirected to dashboard"],
          line_number: 5
        }
      ]
    }

    attrs = Map.merge(defaults, overrides)
    Spec.new(attrs)
  end

  defp scenario_attrs(overrides) do
    defaults = %{
      name: "Test scenario",
      given_steps: ["setup step"],
      when_steps: ["action step"],
      then_steps: ["assertion step"],
      line_number: 10,
      tags: []
    }

    Map.merge(defaults, overrides)
  end

  defp step_fixture(type, description, opts \\ []) do
    Step.new(type, description, opts)
  end

  defp story_fixture(attrs) do
    # `number` mirrors `id` unless a test says otherwise: coverage groups specs
    # by the number in their directory name, and these fixtures set `id` to say
    # "story 1". Defaulting it to `id` keeps that reading true without every
    # call site naming both, and a test that cares about the two diverging
    # passes them separately.
    attrs = Map.put_new(attrs, :number, Map.get(attrs, :id, 1))

    defaults = %{
      id: 1,
      title: "User authentication feature",
      description: "As a user, I want to log in",
      acceptance_criteria: [],
      criteria: [],
      status: :in_progress,
      project_id: Ecto.UUID.generate(),
      account_id: Ecto.UUID.generate()
    }

    struct(Story, Map.merge(defaults, attrs))
  end

  defp criterion_fixture(attrs) do
    defaults = %{
      id: 10,
      description: "User can log in with valid credentials",
      verified: false,
      story_number: 1,
      project_id: Ecto.UUID.generate(),
      account_id: Ecto.UUID.generate()
    }

    struct(Criterion, Map.merge(defaults, attrs))
  end

  # ============================================================================
  # project_summary/1
  # ============================================================================

  describe "project_summary/1" do
    test "returns spec name as header" do
      spec = spec_fixture()

      result = SpecProjector.project_summary(spec)

      assert result =~ "User Authentication"
      assert result =~ ~r/^#.*User Authentication/m
    end

    test "includes all scenario names" do
      spec =
        spec_fixture(%{
          scenarios: [
            scenario_attrs(%{name: "Successful login"}),
            scenario_attrs(%{name: "Failed login"}),
            scenario_attrs(%{name: "Password reset"})
          ]
        })

      result = SpecProjector.project_summary(spec)

      assert result =~ "Successful login"
      assert result =~ "Failed login"
      assert result =~ "Password reset"
    end

    test "includes step descriptions for given/when/then steps" do
      spec =
        spec_fixture(%{
          scenarios: [
            scenario_attrs(%{
              name: "Login test",
              given_steps: ["user has account"],
              when_steps: ["user logs in"],
              then_steps: ["user sees dashboard"]
            })
          ]
        })

      result = SpecProjector.project_summary(spec)

      assert result =~ "user has account"
      assert result =~ "user logs in"
      assert result =~ "user sees dashboard"
    end

    test "excludes implementation code" do
      spec = spec_fixture()

      result = SpecProjector.project_summary(spec)

      # Should not contain code patterns like function calls, do/end blocks, etc.
      refute result =~ ~r/def /
      refute result =~ ~r/do$/
      refute result =~ ~r/end$/
    end

    test "returns compact markdown format" do
      spec = spec_fixture()

      result = SpecProjector.project_summary(spec)

      # Should be markdown with headers and lists
      assert result =~ ~r/^#/m
      assert is_binary(result)
    end
  end

  # ============================================================================
  # project_summary_list/1
  # ============================================================================

  describe "project_summary_list/1" do
    test "returns empty string for empty list" do
      result = SpecProjector.project_summary_list([])

      assert result == ""
    end

    test "formats single spec correctly" do
      spec = spec_fixture(%{name: "Single spec"})

      result = SpecProjector.project_summary_list([spec])

      assert result =~ "Single spec"
    end

    test "formats multiple specs with proper separation" do
      spec1 = spec_fixture(%{name: "First spec"})
      spec2 = spec_fixture(%{name: "Second spec"})
      spec3 = spec_fixture(%{name: "Third spec"})

      result = SpecProjector.project_summary_list([spec1, spec2, spec3])

      assert result =~ "First spec"
      assert result =~ "Second spec"
      assert result =~ "Third spec"
      # Specs should be separated by newlines
      assert result =~ ~r/First spec.*\n.*Second spec/s
    end

    test "preserves spec order in output" do
      specs = [
        spec_fixture(%{name: "Alpha"}),
        spec_fixture(%{name: "Beta"}),
        spec_fixture(%{name: "Gamma"})
      ]

      result = SpecProjector.project_summary_list(specs)

      # Find positions of each spec name
      alpha_pos = :binary.match(result, "Alpha") |> elem(0)
      beta_pos = :binary.match(result, "Beta") |> elem(0)
      gamma_pos = :binary.match(result, "Gamma") |> elem(0)

      assert alpha_pos < beta_pos
      assert beta_pos < gamma_pos
    end
  end

  # ============================================================================
  # project_full/1
  # ============================================================================

  describe "project_full/1" do
    test "includes spec name and file path" do
      spec = spec_fixture(%{name: "Full Spec", file_path: "/path/to/full_spec.exs"})

      result = SpecProjector.project_full(spec)

      assert result =~ "Full Spec"
      assert result =~ "/path/to/full_spec.exs"
    end

    test "includes story_number when present" do
      spec = spec_fixture(%{story_number: 42})

      result = SpecProjector.project_full(spec)

      assert result =~ "42"
      assert result =~ ~r/story/i
    end

    test "includes criterion_id when present" do
      spec = spec_fixture(%{criterion_id: 99})

      result = SpecProjector.project_full(spec)

      assert result =~ "99"
      assert result =~ ~r/criterion/i
    end

    test "shows all scenario details with step types" do
      spec =
        spec_fixture(%{
          scenarios: [
            scenario_attrs(%{
              name: "Detailed scenario",
              given_steps: ["setup"],
              when_steps: ["action"],
              then_steps: ["result"]
            })
          ]
        })

      result = SpecProjector.project_full(spec)

      assert result =~ "Detailed scenario"
      assert result =~ "setup"
      assert result =~ "action"
      assert result =~ "result"
      # Should include step type indicators
      assert result =~ ~r/given|when|then/i
    end

    test "includes step line numbers for traceability" do
      spec =
        spec_fixture(%{
          scenarios: [
            scenario_attrs(%{
              name: "Line number test",
              line_number: 42
            })
          ]
        })

      result = SpecProjector.project_full(spec)

      assert result =~ "42"
    end

    test "includes tags when present" do
      spec = spec_fixture(%{tags: [:integration, :smoke, :critical]})

      result = SpecProjector.project_full(spec)

      assert result =~ "integration"
      assert result =~ "smoke"
      assert result =~ "critical"
    end
  end

  # ============================================================================
  # project_coverage_by_story/2
  # ============================================================================

  describe "project_coverage_by_story/2" do
    test "groups specs by story correctly" do
      spec1 = spec_fixture(%{name: "Spec 1", story_number: 1})
      spec2 = spec_fixture(%{name: "Spec 2", story_number: 1})
      spec3 = spec_fixture(%{name: "Spec 3", story_number: 2})

      story1 = story_fixture(%{id: 1, title: "Story One"})
      story2 = story_fixture(%{id: 2, title: "Story Two"})

      result = SpecProjector.project_coverage_by_story([spec1, spec2, spec3], [story1, story2])

      assert result =~ "Story One"
      assert result =~ "Story Two"
      assert result =~ "Spec 1"
      assert result =~ "Spec 2"
      assert result =~ "Spec 3"
    end

    test "shows stories with full coverage" do
      spec1 = spec_fixture(%{story_number: 1})
      spec2 = spec_fixture(%{story_number: 1})
      story = story_fixture(%{id: 1, title: "Fully covered"})

      result = SpecProjector.project_coverage_by_story([spec1, spec2], [story])

      assert result =~ "Fully covered"
      # Should indicate good coverage
      assert result =~ ~r/✓|complete|full|covered/i
    end

    test "highlights stories with partial coverage" do
      spec = spec_fixture(%{story_number: 1})

      story =
        story_fixture(%{
          id: 1,
          title: "Partial coverage",
          criteria: [
            criterion_fixture(%{id: 1}),
            criterion_fixture(%{id: 2})
          ]
        })

      result = SpecProjector.project_coverage_by_story([spec], [story])

      assert result =~ "Partial coverage"
      # Should indicate partial coverage
      assert result =~ ~r/partial|incomplete|⚠/i
    end

    test "lists stories with no specs" do
      story = story_fixture(%{id: 99, title: "No coverage"})

      result = SpecProjector.project_coverage_by_story([], [story])

      assert result =~ "No coverage"
      # Should indicate missing coverage
      assert result =~ ~r/missing|none|uncovered|✗/i
    end

    test "includes coverage indicators or percentages" do
      spec = spec_fixture(%{story_number: 1})
      story = story_fixture(%{id: 1, title: "Story with metrics"})

      result = SpecProjector.project_coverage_by_story([spec], [story])

      # Should include some form of coverage metric
      assert result =~ ~r/\d+%|✓|✗|⚠|covered|uncovered/i
    end

    test "returns empty string for empty inputs" do
      result = SpecProjector.project_coverage_by_story([], [])

      assert result == ""
    end
  end

  # ============================================================================
  # project_coverage_by_criterion/2
  # ============================================================================

  describe "project_coverage_by_criterion/2" do
    test "matches specs to criteria by ID" do
      spec = spec_fixture(%{name: "Criterion spec", criterion_id: 10})
      criterion = criterion_fixture(%{id: 10, description: "Test criterion"})

      result = SpecProjector.project_coverage_by_criterion([spec], [criterion])

      assert result =~ "Test criterion"
      assert result =~ "Criterion spec"
    end

    test "shows covered criteria with spec links" do
      spec = spec_fixture(%{criterion_id: 5, name: "Covering spec"})
      criterion = criterion_fixture(%{id: 5, description: "Covered criterion"})

      result = SpecProjector.project_coverage_by_criterion([spec], [criterion])

      assert result =~ "Covered criterion"
      assert result =~ "Covering spec"
      # Should show as covered
      assert result =~ ~r/✓|covered|complete/i
    end

    test "highlights uncovered criteria" do
      criterion = criterion_fixture(%{id: 20, description: "Uncovered criterion"})

      result = SpecProjector.project_coverage_by_criterion([], [criterion])

      assert result =~ "Uncovered criterion"
      # Should show as uncovered
      assert result =~ ~r/✗|uncovered|missing/i
    end

    test "handles criteria with multiple specs" do
      spec1 = spec_fixture(%{criterion_id: 15, name: "First spec"})
      spec2 = spec_fixture(%{criterion_id: 15, name: "Second spec"})
      criterion = criterion_fixture(%{id: 15, description: "Multi-spec criterion"})

      result = SpecProjector.project_coverage_by_criterion([spec1, spec2], [criterion])

      assert result =~ "Multi-spec criterion"
      assert result =~ "First spec"
      assert result =~ "Second spec"
    end

    test "returns organized markdown format" do
      spec = spec_fixture(%{criterion_id: 1})
      criterion = criterion_fixture(%{id: 1})

      result = SpecProjector.project_coverage_by_criterion([spec], [criterion])

      # Should be valid markdown
      assert is_binary(result)
      assert result =~ ~r/^[#-]/m
    end

    test "handles empty inputs gracefully" do
      result = SpecProjector.project_coverage_by_criterion([], [])

      assert result == ""
    end
  end

  # ============================================================================
  # format_scenario/1
  # ============================================================================

  describe "format_scenario/1" do
    test "formats scenario name as header" do
      scenario = Scenario.new(%{name: "Login scenario"})

      result = SpecProjector.format_scenario(scenario)

      assert result =~ "Login scenario"
      assert result =~ ~r/^#.*Login scenario/m
    end

    test "groups steps by type" do
      scenario =
        Scenario.new(%{
          name: "Multi-step scenario",
          given_steps: ["setup 1", "setup 2"],
          when_steps: ["action 1"],
          then_steps: ["result 1", "result 2"]
        })

      result = SpecProjector.format_scenario(scenario)

      # Should have distinct sections for each step type
      assert result =~ ~r/given/i
      assert result =~ ~r/when/i
      assert result =~ ~r/then/i
    end

    test "preserves step descriptions" do
      scenario =
        Scenario.new(%{
          name: "Logout scenario",
          given_steps: ["user is logged in"],
          when_steps: ["user clicks logout"],
          then_steps: ["user is logged out"]
        })

      result = SpecProjector.format_scenario(scenario)

      assert result =~ "user is logged in"
      assert result =~ "user clicks logout"
      assert result =~ "user is logged out"
    end

    test "returns valid markdown structure" do
      scenario = Scenario.new(%{name: "Test scenario"})

      result = SpecProjector.format_scenario(scenario)

      assert is_binary(result)
      # Should have markdown headers or lists
      assert result =~ ~r/[#*-]/
    end
  end

  # ============================================================================
  # format_step/1
  # ============================================================================

  describe "format_step/1" do
    test "includes step type prefix" do
      given_step = step_fixture(:given, "setup step")
      when_step = step_fixture(:when, "action step")
      then_step = step_fixture(:then, "result step")

      given_result = SpecProjector.format_step(given_step)
      when_result = SpecProjector.format_step(when_step)
      then_result = SpecProjector.format_step(then_step)

      assert given_result =~ ~r/given/i
      assert when_result =~ ~r/when/i
      assert then_result =~ ~r/then/i
    end

    test "includes step description" do
      step = step_fixture(:given, "user has valid credentials")

      result = SpecProjector.format_step(step)

      assert result =~ "user has valid credentials"
    end

    test "includes line number when present" do
      step = step_fixture(:when, "user submits form", line: 42)

      result = SpecProjector.format_step(step)

      assert result =~ "42"
    end

    test "handles all step types (given, when, then)" do
      given = step_fixture(:given, "given step", line: 10)
      when_step = step_fixture(:when, "when step", line: 11)
      then_step = step_fixture(:then, "then step", line: 12)

      given_result = SpecProjector.format_step(given)
      when_result = SpecProjector.format_step(when_step)
      then_result = SpecProjector.format_step(then_step)

      assert given_result =~ "given step"
      assert when_result =~ "when step"
      assert then_result =~ "then step"

      assert given_result =~ "10"
      assert when_result =~ "11"
      assert then_result =~ "12"
    end
  end
end
