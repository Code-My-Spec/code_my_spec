defmodule CodeMySpec.BddSpecs.ScenarioTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.BddSpecs.Scenario

  describe "new/1" do
    test "creates scenario with name only" do
      attrs = %{name: "User logs in successfully"}

      scenario = Scenario.new(attrs)

      assert scenario.name == "User logs in successfully"
      assert scenario.given_steps == []
      assert scenario.when_steps == []
      assert scenario.then_steps == []
      assert scenario.line_number == nil
      assert scenario.tags == []
    end

    test "creates scenario with all step types populated" do
      attrs = %{
        name: "User completes checkout",
        given_steps: ["user is logged in", "cart has items"],
        when_steps: ["user clicks checkout"],
        then_steps: ["order is created", "confirmation is shown"]
      }

      scenario = Scenario.new(attrs)

      assert scenario.name == "User completes checkout"
      assert scenario.given_steps == ["user is logged in", "cart has items"]
      assert scenario.when_steps == ["user clicks checkout"]
      assert scenario.then_steps == ["order is created", "confirmation is shown"]
    end

    test "defaults step lists to empty when not provided" do
      attrs = %{name: "Simple scenario"}

      scenario = Scenario.new(attrs)

      assert scenario.given_steps == []
      assert scenario.when_steps == []
      assert scenario.then_steps == []
    end

    test "accepts line_number when provided" do
      attrs = %{name: "Scenario with line", line_number: 42}

      scenario = Scenario.new(attrs)

      assert scenario.line_number == 42
    end

    test "accepts tags when provided" do
      attrs = %{name: "Tagged scenario", tags: [:wip, :integration]}

      scenario = Scenario.new(attrs)

      assert scenario.tags == [:wip, :integration]
    end

    test "preserves order of steps in each list" do
      attrs = %{
        name: "Order preservation test",
        given_steps: ["first given", "second given", "third given"],
        when_steps: ["first when", "second when"],
        then_steps: ["first then", "second then", "third then", "fourth then"]
      }

      scenario = Scenario.new(attrs)

      assert scenario.given_steps == ["first given", "second given", "third given"]
      assert scenario.when_steps == ["first when", "second when"]
      assert scenario.then_steps == ["first then", "second then", "third then", "fourth then"]
    end
  end

  describe "changeset/2" do
    test "returns valid changeset with all required fields" do
      attrs = valid_attrs()

      changeset = Scenario.changeset(%Scenario{}, attrs)

      assert changeset.valid?
      assert changeset.changes.name == "Valid scenario"
    end

    test "returns invalid changeset when name is missing" do
      attrs = valid_attrs() |> Map.delete(:name)

      changeset = Scenario.changeset(%Scenario{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "returns invalid changeset when name is empty string" do
      attrs = valid_attrs(%{name: ""})

      changeset = Scenario.changeset(%Scenario{}, attrs)

      refute changeset.valid?
      assert "should be at least 1 character(s)" in errors_on(changeset).name
    end

    test "returns invalid changeset when name exceeds 500 characters" do
      attrs = valid_attrs(%{name: String.duplicate("a", 501)})

      changeset = Scenario.changeset(%Scenario{}, attrs)

      refute changeset.valid?
      assert "should be at most 500 character(s)" in errors_on(changeset).name
    end

    test "returns invalid changeset when line_number is negative" do
      attrs = valid_attrs(%{line_number: -1})

      changeset = Scenario.changeset(%Scenario{}, attrs)

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).line_number
    end

    test "returns invalid changeset when line_number is zero" do
      attrs = valid_attrs(%{line_number: 0})

      changeset = Scenario.changeset(%Scenario{}, attrs)

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).line_number
    end

    test "accepts optional given_steps, when_steps, then_steps" do
      attrs =
        valid_attrs(%{
          given_steps: ["step 1", "step 2"],
          when_steps: ["action"],
          then_steps: ["outcome"]
        })

      changeset = Scenario.changeset(%Scenario{}, attrs)

      assert changeset.valid?
      assert changeset.changes.given_steps == ["step 1", "step 2"]
      assert changeset.changes.when_steps == ["action"]
      assert changeset.changes.then_steps == ["outcome"]
    end

    test "defaults step lists to empty arrays when not provided" do
      attrs = valid_attrs()

      changeset = Scenario.changeset(%Scenario{}, attrs)

      assert changeset.valid?
      # Check defaults are applied
      scenario = Ecto.Changeset.apply_changes(changeset)
      assert scenario.given_steps == []
      assert scenario.when_steps == []
      assert scenario.then_steps == []
    end

    test "accepts optional tags list" do
      attrs = valid_attrs(%{tags: [:smoke, :regression]})

      changeset = Scenario.changeset(%Scenario{}, attrs)

      assert changeset.valid?
      assert changeset.changes.tags == [:smoke, :regression]
    end

    test "preserves step order in changeset" do
      attrs =
        valid_attrs(%{
          given_steps: ["z", "a", "m"],
          when_steps: ["w", "a"],
          then_steps: ["x", "y", "z"]
        })

      changeset = Scenario.changeset(%Scenario{}, attrs)

      assert changeset.valid?
      assert changeset.changes.given_steps == ["z", "a", "m"]
      assert changeset.changes.when_steps == ["w", "a"]
      assert changeset.changes.then_steps == ["x", "y", "z"]
    end
  end

  describe "add_given_step/2" do
    test "appends step to empty given_steps list" do
      scenario = %Scenario{name: "test", given_steps: []}

      updated = Scenario.add_given_step(scenario, "new given step")

      assert updated.given_steps == ["new given step"]
    end

    test "appends step to existing given_steps list" do
      scenario = %Scenario{name: "test", given_steps: ["existing step"]}

      updated = Scenario.add_given_step(scenario, "new step")

      assert updated.given_steps == ["existing step", "new step"]
    end

    test "preserves existing steps when adding new step" do
      scenario = %Scenario{name: "test", given_steps: ["step 1", "step 2"]}

      updated = Scenario.add_given_step(scenario, "step 3")

      assert updated.given_steps == ["step 1", "step 2", "step 3"]
    end

    test "maintains step order" do
      scenario = %Scenario{name: "test", given_steps: []}

      updated =
        scenario
        |> Scenario.add_given_step("first")
        |> Scenario.add_given_step("second")
        |> Scenario.add_given_step("third")

      assert updated.given_steps == ["first", "second", "third"]
    end
  end

  describe "add_when_step/2" do
    test "appends step to empty when_steps list" do
      scenario = %Scenario{name: "test", when_steps: []}

      updated = Scenario.add_when_step(scenario, "new when step")

      assert updated.when_steps == ["new when step"]
    end

    test "appends step to existing when_steps list" do
      scenario = %Scenario{name: "test", when_steps: ["existing step"]}

      updated = Scenario.add_when_step(scenario, "new step")

      assert updated.when_steps == ["existing step", "new step"]
    end

    test "preserves existing steps when adding new step" do
      scenario = %Scenario{name: "test", when_steps: ["step 1", "step 2"]}

      updated = Scenario.add_when_step(scenario, "step 3")

      assert updated.when_steps == ["step 1", "step 2", "step 3"]
    end

    test "maintains step order" do
      scenario = %Scenario{name: "test", when_steps: []}

      updated =
        scenario
        |> Scenario.add_when_step("first")
        |> Scenario.add_when_step("second")
        |> Scenario.add_when_step("third")

      assert updated.when_steps == ["first", "second", "third"]
    end
  end

  describe "add_then_step/2" do
    test "appends step to empty then_steps list" do
      scenario = %Scenario{name: "test", then_steps: []}

      updated = Scenario.add_then_step(scenario, "new then step")

      assert updated.then_steps == ["new then step"]
    end

    test "appends step to existing then_steps list" do
      scenario = %Scenario{name: "test", then_steps: ["existing step"]}

      updated = Scenario.add_then_step(scenario, "new step")

      assert updated.then_steps == ["existing step", "new step"]
    end

    test "preserves existing steps when adding new step" do
      scenario = %Scenario{name: "test", then_steps: ["step 1", "step 2"]}

      updated = Scenario.add_then_step(scenario, "step 3")

      assert updated.then_steps == ["step 1", "step 2", "step 3"]
    end

    test "maintains step order" do
      scenario = %Scenario{name: "test", then_steps: []}

      updated =
        scenario
        |> Scenario.add_then_step("first")
        |> Scenario.add_then_step("second")
        |> Scenario.add_then_step("third")

      assert updated.then_steps == ["first", "second", "third"]
    end
  end

  describe "step_count/1" do
    test "returns 0 for scenario with no steps" do
      scenario = %Scenario{name: "test", given_steps: [], when_steps: [], then_steps: []}

      assert Scenario.step_count(scenario) == 0
    end

    test "returns correct count for scenario with only given steps" do
      scenario = %Scenario{name: "test", given_steps: ["step 1", "step 2"], when_steps: [], then_steps: []}

      assert Scenario.step_count(scenario) == 2
    end

    test "returns correct count for scenario with only when steps" do
      scenario = %Scenario{name: "test", given_steps: [], when_steps: ["step 1", "step 2", "step 3"], then_steps: []}

      assert Scenario.step_count(scenario) == 3
    end

    test "returns correct count for scenario with only then steps" do
      scenario = %Scenario{name: "test", given_steps: [], when_steps: [], then_steps: ["step 1"]}

      assert Scenario.step_count(scenario) == 1
    end

    test "returns correct count for scenario with all step types" do
      scenario = %Scenario{
        name: "test",
        given_steps: ["given 1"],
        when_steps: ["when 1"],
        then_steps: ["then 1"]
      }

      assert Scenario.step_count(scenario) == 3
    end

    test "returns correct count for scenario with multiple steps per type" do
      scenario = %Scenario{
        name: "test",
        given_steps: ["given 1", "given 2", "given 3"],
        when_steps: ["when 1", "when 2"],
        then_steps: ["then 1", "then 2", "then 3", "then 4"]
      }

      assert Scenario.step_count(scenario) == 9
    end
  end

  describe "has_steps?/1" do
    test "returns false for scenario with no steps" do
      scenario = %Scenario{name: "test", given_steps: [], when_steps: [], then_steps: []}

      refute Scenario.has_steps?(scenario)
    end

    test "returns true for scenario with only given steps" do
      scenario = %Scenario{name: "test", given_steps: ["step"], when_steps: [], then_steps: []}

      assert Scenario.has_steps?(scenario)
    end

    test "returns true for scenario with only when steps" do
      scenario = %Scenario{name: "test", given_steps: [], when_steps: ["step"], then_steps: []}

      assert Scenario.has_steps?(scenario)
    end

    test "returns true for scenario with only then steps" do
      scenario = %Scenario{name: "test", given_steps: [], when_steps: [], then_steps: ["step"]}

      assert Scenario.has_steps?(scenario)
    end

    test "returns true for scenario with steps in multiple types" do
      scenario = %Scenario{
        name: "test",
        given_steps: ["given"],
        when_steps: ["when"],
        then_steps: []
      }

      assert Scenario.has_steps?(scenario)
    end
  end

  describe "all_steps/1" do
    test "returns empty list for scenario with no steps" do
      scenario = %Scenario{name: "test", given_steps: [], when_steps: [], then_steps: []}

      assert Scenario.all_steps(scenario) == []
    end

    test "returns only given steps when other types are empty" do
      scenario = %Scenario{name: "test", given_steps: ["given 1", "given 2"], when_steps: [], then_steps: []}

      assert Scenario.all_steps(scenario) == ["given 1", "given 2"]
    end

    test "returns only when steps when other types are empty" do
      scenario = %Scenario{name: "test", given_steps: [], when_steps: ["when 1", "when 2"], then_steps: []}

      assert Scenario.all_steps(scenario) == ["when 1", "when 2"]
    end

    test "returns only then steps when other types are empty" do
      scenario = %Scenario{name: "test", given_steps: [], when_steps: [], then_steps: ["then 1", "then 2"]}

      assert Scenario.all_steps(scenario) == ["then 1", "then 2"]
    end

    test "returns all steps in correct order (given, then when, then then)" do
      scenario = %Scenario{
        name: "test",
        given_steps: ["given 1", "given 2"],
        when_steps: ["when 1"],
        then_steps: ["then 1", "then 2"]
      }

      assert Scenario.all_steps(scenario) == ["given 1", "given 2", "when 1", "then 1", "then 2"]
    end

    test "preserves step order within each type" do
      scenario = %Scenario{
        name: "test",
        given_steps: ["z", "a", "m"],
        when_steps: ["x", "b"],
        then_steps: ["y", "c", "d"]
      }

      assert Scenario.all_steps(scenario) == ["z", "a", "m", "x", "b", "y", "c", "d"]
    end
  end

  # Fixture functions

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "Valid scenario"
      },
      overrides
    )
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
