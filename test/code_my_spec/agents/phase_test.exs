defmodule CodeMySpec.Agents.PhaseTest do
  @moduledoc """
  The runner's own three answers, proven without a model.

  Completing, parking for a person, and giving up are `Phase`'s logic rather than
  any phase's, and the distinction the whole design rests on is that only one of
  them spends an attempt. A cassette per branch would prove the model's behaviour
  instead of this module's, so the model is a stub that returns whatever the test
  queued.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Phase

  # -- a phase that does nothing but what the test told it to -----------------

  # `verdicts` is read by attempt number rather than consumed, because the runner
  # calls `commit/2` and then `evaluate/1` within one attempt — popping in the
  # first would hand the second the *next* attempt's verdict and quietly shift
  # every assertion in this file by one.
  defmodule Scripted do
    @moduledoc false
    @behaviour CodeMySpec.Agents.Phase

    defstruct verdicts: [], committed: [], attempts: 0

    @impl true
    def goal(%__MODULE__{}), do: "do the thing"

    @impl true
    def tools(%__MODULE__{}) do
      [
        Alloy.Tool.inline(
          name: "submit",
          description: "s",
          input_schema: %{type: "object", properties: %{}},
          execute: fn _input, _context -> {:ok, "ok"} end
        )
      ]
    end

    @impl true
    def commit(%__MODULE__{committed: committed, attempts: attempts} = state, input) do
      {:ok, %{state | committed: committed ++ [input], attempts: attempts + 1}}
    end

    @impl true
    def evaluate(%__MODULE__{verdicts: verdicts, attempts: attempts}) do
      Enum.at(verdicts, attempts - 1, :complete)
    end
  end

  # -- a model that answers from a queue --------------------------------------

  defmodule StubModel do
    @moduledoc false

    def run(prompt, _tools, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:prompt, prompt})

      opts
      |> Keyword.fetch!(:answers)
      |> Agent.get_and_update(fn
        [head | rest] -> {head, rest}
        [] -> {{:error, :exhausted}, []}
      end)
      |> to_result()
    end

    defp to_result({:error, reason}), do: {:error, reason}
    defp to_result(input), do: {:ok, input}
  end

  setup do
    {:ok, answers} = Agent.start_link(fn -> [] end)
    %{answers: answers}
  end

  defp opts(answers, extra \\ []) do
    [model_module: StubModel, answers: answers, test_pid: self()] ++ extra
  end

  defp queue(answers, list), do: Agent.update(answers, fn _ -> list end)

  describe "completing" do
    test "returns the committed state", %{answers: answers} do
      queue(answers, [%{"a" => 1}])
      state = %Scripted{verdicts: [:complete]}

      assert {:complete, %Scripted{committed: [%{"a" => 1}]}} =
               Phase.advance(Scripted, state, opts(answers))
    end
  end

  describe "parking for a person" do
    test "is not an error and does not retry", %{answers: answers} do
      queue(answers, [%{"q" => "who uses it?"}])
      state = %Scripted{verdicts: [{:ask, "who uses it?"}]}

      assert {:ask, "who uses it?", %Scripted{}} = Phase.advance(Scripted, state, opts(answers))

      # One call only: a parked phase waits for a human rather than trying again.
      assert_received {:prompt, _}
      refute_received {:prompt, _}
    end
  end

  describe "an unusable answer" do
    test "runs again with the feedback appended to the goal", %{answers: answers} do
      queue(answers, [%{"first" => true}, %{"second" => true}])
      state = %Scripted{verdicts: [{:incomplete, "`needs_sign_in` was not set"}, :complete]}

      assert {:complete, %Scripted{committed: [%{"first" => true}, %{"second" => true}]}} =
               Phase.advance(Scripted, state, opts(answers))

      assert_received {:prompt, first}
      refute first =~ "could not be used"

      assert_received {:prompt, second}
      assert second =~ "`needs_sign_in` was not set"

      # The instruction has to be the last word, or the goal's own closing line
      # is what the model acts on and the same mistake comes back.
      assert String.contains?(second, "Answer again, fixing that.")
    end

    test "gives up after the attempt budget, naming the last feedback", %{answers: answers} do
      queue(answers, [%{"a" => 1}, %{"a" => 2}, %{"a" => 3}, %{"a" => 4}])

      state = %Scripted{
        verdicts: [{:incomplete, "one"}, {:incomplete, "two"}, {:incomplete, "three"}]
      }

      assert {:error, {:not_converging, "three"}} =
               Phase.advance(Scripted, state, opts(answers, attempts: 3))
    end

    test "the budget is per call, so a long conversation is not penalised", %{answers: answers} do
      queue(answers, [%{"a" => 1}, %{"a" => 2}])
      state = %Scripted{verdicts: [{:incomplete, "again"}, {:ask, "and who signs in?"}]}

      assert {:ask, "and who signs in?", _} = Phase.advance(Scripted, state, opts(answers))
    end
  end

  describe "a failing model" do
    test "propagates rather than retrying", %{answers: answers} do
      queue(answers, [])
      state = %Scripted{verdicts: [:complete]}

      assert {:error, :exhausted} = Phase.advance(Scripted, state, opts(answers))
    end
  end
end
