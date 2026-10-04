defmodule CodeMySpec.PromotionQueue.TriageTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.PromotionQueue.Triage

  defp finding(source, path), do: %{source: source, file_path: path}

  describe "lone_failure/1" do
    test "one finding is re-run once, as the flake it may be" do
      assert {:rerun, "exunit"} = Triage.lone_failure([finding("exunit", "test/a_test.exs")])
    end

    test "more than one is not" do
      assert :no =
               Triage.lone_failure([
                 finding("exunit", "test/a_test.exs"),
                 finding("credo", "lib/a.ex")
               ])
    end
  end

  describe "culprit/2" do
    test "findings all in one candidate's files name that candidate" do
      changed = %{a: ["lib/a.ex"], b: ["lib/b.ex", "test/b_test.exs"]}

      assert {:culprit, :b} =
               Triage.culprit(
                 [finding("compiler", "lib/b.ex"), finding("exunit", "test/b_test.exs")],
                 changed
               )
    end

    test "findings split across candidates are not attributable" do
      changed = %{a: ["lib/a.ex"], b: ["lib/b.ex"]}

      assert :unknown =
               Triage.culprit(
                 [finding("compiler", "lib/a.ex"), finding("compiler", "lib/b.ex")],
                 changed
               )
    end

    test "a file both candidates changed is not attributable" do
      changed = %{a: ["lib/shared.ex"], b: ["lib/shared.ex"]}
      assert :unknown = Triage.culprit([finding("compiler", "lib/shared.ex")], changed)
    end

    test "a finding in a file no candidate changed is not attributable" do
      assert :unknown =
               Triage.culprit([finding("exunit", "test/other_test.exs")], %{a: ["lib/a.ex"]})
    end

    test "a finding with no file is not attributable" do
      assert :unknown = Triage.culprit([finding("spex", "unknown")], %{a: ["unknown"]})
      assert :unknown = Triage.culprit([finding("spex", nil)], %{a: ["lib/a.ex"]})
    end
  end

  describe "split/1" do
    test "gates the first half, rounding up" do
      assert {[1, 2], [3]} = Triage.split([1, 2, 3])
      assert {[1, 2], [3, 4]} = Triage.split([1, 2, 3, 4])
      assert {[1], []} = Triage.split([1])
    end
  end
end
