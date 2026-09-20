defmodule CodeMySpec.Intake.Phases.ShapeTest do
  @moduledoc """
  Phase one, against the recordings the shaper it replaces was proven on.

  The strongest thing available for a port: `test/cassettes/intake` holds the
  exact bytes a real Anthropic call was made with, so asserting the phase builds
  the same prompt is evidence the move changed nothing the model can see. A
  cassette replays on method and uri alone, so nothing in the replay itself would
  have caught a drifted prompt.

  No database — `goal/1` reads a description and `commit/2` folds a map, which is
  what "nothing here writes" buys.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Intake.Phases.Shape
  alias CodeMySpec.Intake.Plan
  alias CodeMySpec.Intake.Shaper

  @cassette_dir "test/cassettes/intake"

  @salon "a booking tool for hair salons, my clients book their own slots"
  @vague "I want a tool to help me keep track of things for my business"

  @at_cap [
    %{question: "Do your clients log in to book?", answer: "yes, they create an account"},
    %{
      question: "Is this for one salon, or many separate salons each with their own data?",
      answer: "just my one salon"
    }
  ]

  defp recorded_prompt(name) do
    Path.join(@cassette_dir, name <> ".json")
    |> File.read!()
    |> Jason.decode!()
    |> get_in([
      "interactions",
      Access.at(0),
      "request",
      "body_json",
      "messages",
      Access.at(0),
      "content"
    ])
  end

  defp state(description, turns \\ []) do
    Shape.new(%Plan{description: description}, turns)
  end

  describe "the prompt" do
    test "is byte-identical to the one recorded for the shaper asking" do
      assert Shape.goal(state(@vague)) == recorded_prompt("shaper_asks")
    end

    test "is byte-identical to the one recorded for the shaper concluding" do
      assert Shape.goal(state(@salon, @at_cap)) == recorded_prompt("shaper_concludes")
    end
  end

  describe "the tool" do
    test "is the one the recording names, with the same four required fields" do
      [tool] = Shape.tools(state(@salon))

      assert tool.name == "shape_plan"

      assert tool.input_schema.required == [
               "question",
               "needs_sign_in",
               "separate_copies",
               "who_uses"
             ]
    end
  end

  describe "reading what the model said" do
    test "a real false is an answer, not a missing one" do
      {:ok, committed} =
        Shape.commit(state(@salon, @at_cap), %{
          "question" => "",
          "needs_sign_in" => true,
          "separate_copies" => false,
          "who_uses" => "the salon owner"
        })

      assert Shape.evaluate(committed) == :complete

      assert Shape.answers(committed) == %{
               needs_sign_in: true,
               separate_copies: false,
               who_uses: "the salon owner"
             }
    end

    test "atom keys work too, so a stub does not have to imitate the wire" do
      {:ok, committed} =
        Shape.commit(state(@salon), %{
          question: "",
          needs_sign_in: false,
          separate_copies: false,
          who_uses: "me"
        })

      assert Shape.evaluate(committed) == :complete
    end

    test "the question never reaches the answers" do
      {:ok, committed} =
        Shape.commit(state(@salon), %{
          "question" => "who books the slots?",
          "needs_sign_in" => true,
          "separate_copies" => false,
          "who_uses" => "clients"
        })

      refute Map.has_key?(Shape.answers(committed), :question)
    end

    test "a boolean the model left out asks for that field by name" do
      {:ok, committed} =
        Shape.commit(state(@salon, @at_cap), %{
          "question" => "",
          "needs_sign_in" => nil,
          "separate_copies" => false,
          "who_uses" => "the owner"
        })

      assert {:incomplete, feedback} = Shape.evaluate(committed)
      assert feedback =~ "needs_sign_in"
    end
  end

  describe "the two-question budget" do
    test "a question asked under the cap parks the phase" do
      {:ok, committed} =
        Shape.commit(state(@vague), %{
          "question" => "who uses this day to day?",
          "needs_sign_in" => true,
          "separate_copies" => false,
          "who_uses" => "unclear"
        })

      assert Shape.evaluate(committed) == {:ask, "who uses this day to day?"}
    end

    test "a question asked at the cap is dropped, and the answers stand" do
      {:ok, committed} =
        Shape.commit(state(@salon, @at_cap), %{
          "question" => "one more thing — how many chairs?",
          "needs_sign_in" => true,
          "separate_copies" => false,
          "who_uses" => "the salon owner"
        })

      assert Shape.evaluate(committed) == :complete
    end

    test "a whitespace-only question is not a question" do
      {:ok, committed} =
        Shape.commit(state(@vague), %{
          "question" => "   ",
          "needs_sign_in" => true,
          "separate_copies" => true,
          "who_uses" => "shop owners"
        })

      assert Shape.evaluate(committed) == :complete
    end

    test "the cap is what the shaper it replaces used" do
      assert Shape.max_questions() == Shaper.max_questions()
    end
  end
end
