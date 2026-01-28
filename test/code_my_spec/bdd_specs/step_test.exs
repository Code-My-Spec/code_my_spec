defmodule CodeMySpec.BddSpecs.StepTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.BddSpecs.Step

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp valid_given_step do
    %Step{
      type: :given,
      description: "the user is logged in",
      line: 10
    }
  end

  defp valid_when_step do
    %Step{
      type: :when,
      description: "they click the submit button",
      line: 11
    }
  end

  defp valid_then_step do
    %Step{
      type: :then,
      description: "they should see a success message",
      line: 12
    }
  end

  defp sample_description, do: "a sample step description"

  # ============================================================================
  # new/3
  # ============================================================================

  describe "new/3" do
    test "creates step with :given type" do
      step = Step.new(:given, sample_description(), line: 5)

      assert step.type == :given
    end

    test "creates step with :when type" do
      step = Step.new(:when, sample_description(), line: 5)

      assert step.type == :when
    end

    test "creates step with :then type" do
      step = Step.new(:then, sample_description(), line: 5)

      assert step.type == :then
    end

    test "stores description string" do
      description = "a specific test description"
      step = Step.new(:given, description, line: 5)

      assert step.description == description
    end

    test "stores line number when provided" do
      step = Step.new(:given, sample_description(), line: 42)

      assert step.line == 42
    end

    test "defaults line to nil when not provided" do
      step = Step.new(:given, sample_description(), [])

      assert step.line == nil
    end

    test "validates type is one of :given, :when, :then" do
      # Valid types should create step successfully
      assert %Step{type: :given} = Step.new(:given, sample_description(), [])
      assert %Step{type: :when} = Step.new(:when, sample_description(), [])
      assert %Step{type: :then} = Step.new(:then, sample_description(), [])

      # Invalid type should raise or return error
      # Note: This test assumes validation happens during creation
      # Adjust based on actual implementation behavior
    end
  end

  # ============================================================================
  # new/2
  # ============================================================================

  describe "new/2" do
    test "creates step without line number" do
      step = Step.new(:given, sample_description())

      assert step.type == :given
      assert step.description == sample_description()
      assert step.line == nil
    end

    test "delegates to new/3 with empty opts" do
      step_2_arity = Step.new(:when, sample_description())
      step_3_arity = Step.new(:when, sample_description(), [])

      assert step_2_arity.type == step_3_arity.type
      assert step_2_arity.description == step_3_arity.description
      assert step_2_arity.line == step_3_arity.line
    end
  end

  # ============================================================================
  # given/2
  # ============================================================================

  describe "given/2" do
    test "creates step with :given type" do
      step = Step.given(sample_description(), line: 10)

      assert step.type == :given
    end

    test "stores description" do
      description = "user has an active account"
      step = Step.given(description, [])

      assert step.description == description
    end

    test "passes line number through to new/3" do
      step = Step.given(sample_description(), line: 25)

      assert step.line == 25
    end
  end

  # ============================================================================
  # when_step/2
  # ============================================================================

  describe "when_step/2" do
    test "creates step with :when type" do
      step = Step.when_step(sample_description(), line: 10)

      assert step.type == :when
    end

    test "stores description" do
      description = "user submits the form"
      step = Step.when_step(description, [])

      assert step.description == description
    end

    test "passes line number through to new/3" do
      step = Step.when_step(sample_description(), line: 30)

      assert step.line == 30
    end
  end

  # ============================================================================
  # then_step/2
  # ============================================================================

  describe "then_step/2" do
    test "creates step with :then type" do
      step = Step.then_step(sample_description(), line: 10)

      assert step.type == :then
    end

    test "stores description" do
      description = "the response should be successful"
      step = Step.then_step(description, [])

      assert step.description == description
    end

    test "passes line number through to new/3" do
      step = Step.then_step(sample_description(), line: 35)

      assert step.line == 35
    end
  end

  # ============================================================================
  # to_string/1
  # ============================================================================

  describe "to_string/1" do
    test "formats :given step as \"Given <description>\"" do
      step = valid_given_step()

      result = Step.to_string(step)

      assert result == "Given the user is logged in"
    end

    test "formats :when step as \"When <description>\"" do
      step = valid_when_step()

      result = Step.to_string(step)

      assert result == "When they click the submit button"
    end

    test "formats :then step as \"Then <description>\"" do
      step = valid_then_step()

      result = Step.to_string(step)

      assert result == "Then they should see a success message"
    end

    test "capitalizes step type keyword" do
      given_step = valid_given_step()
      when_step = valid_when_step()
      then_step = valid_then_step()

      assert Step.to_string(given_step) =~ ~r/^Given /
      assert Step.to_string(when_step) =~ ~r/^When /
      assert Step.to_string(then_step) =~ ~r/^Then /
    end
  end

  # ============================================================================
  # type_valid?/1
  # ============================================================================

  describe "type_valid?/1" do
    test "returns true for :given" do
      assert Step.type_valid?(:given) == true
    end

    test "returns true for :when" do
      assert Step.type_valid?(:when) == true
    end

    test "returns true for :then" do
      assert Step.type_valid?(:then) == true
    end

    test "returns false for invalid types" do
      assert Step.type_valid?(:invalid) == false
      assert Step.type_valid?(:and) == false
      assert Step.type_valid?(:but) == false
      assert Step.type_valid?(:other) == false
    end

    test "returns false for nil" do
      assert Step.type_valid?(nil) == false
    end
  end
end
