defmodule CodeMySpec.BddSpecs.StampTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.BddSpecs.Stamp

  @story %{id: 10, number: 460, title: "BDD Specification Lifecycle"}

  defp criterion(attrs) do
    Map.merge(
      %{
        id: 1482,
        number: 7,
        story_id: 10,
        description: "A missing spec is reported",
        spec_path: nil,
        retired_at: nil
      },
      attrs
    )
  end

  defp spex(opts \\ "") do
    """
    defmodule Sample do
      use CodeMySpecSpex.Case

      spex "It is reported"#{opts} do
        scenario "one" do
          then_ "it holds", context do
            {:ok, context}
          end
        end
      end
    end
    """
  end

  test "a recorded spec_path finds the criterion, and the file is stamped and moved" do
    path = "test/spex/460_bdd_specification_lifecycle/criterion_5531_old_spex.exs"

    [action] = Stamp.plan([{path, spex()}], [criterion(%{spec_path: path})], %{10 => @story})

    assert %{action: :stamp, number: 7} = action
    assert action.content =~ ~s(spex "It is reported", criterion: 7 do)

    assert action.to ==
             "test/spex/460_bdd_specification_lifecycle/criterion_7_a_missing_spec_is_reported_spex.exs"
  end

  test "a filename naming the criterion's id finds it when no path is recorded" do
    path = "test/spex/anything/criterion_1482_whatever_spex.exs"

    assert [%{action: :stamp, number: 7}] =
             Stamp.plan([{path, spex()}], [criterion(%{})], %{10 => @story})
  end

  test "a file already naming its criterion is left alone" do
    assert [%{action: :skip, number: 3}] =
             Stamp.plan([{"test/spex/x_spex.exs", spex(", criterion: 3")}], [], %{})
  end

  test "an unmatched, retired or second file is reported, not guessed" do
    retired = criterion(%{id: 2, number: 8, retired_at: DateTime.utc_now()})

    files = [
      {"test/spex/a/criterion_1482_first_spex.exs", spex()},
      {"test/spex/a/criterion_1482_second_spex.exs", spex()},
      {"test/spex/a/criterion_2_dropped_spex.exs", spex()},
      {"test/spex/a/nothing_spex.exs", spex()}
    ]

    assert [
             %{action: :stamp},
             %{action: :unmatched, why: "criterion 7 is already covered" <> _},
             %{action: :unmatched, why: "criterion 8 is retired"},
             %{action: :unmatched}
           ] = Stamp.plan(files, [criterion(%{}), retired], %{10 => @story})
  end

  test "stamps a spex call whose options run over several lines" do
    content = """
    defmodule Sample do
      spex "It is reported",
           fail_on_error_logs: false do
        scenario "one" do
        end
      end
    end
    """

    assert {:ok, stamped} = Stamp.stamp(content, 7)
    assert stamped =~ "fail_on_error_logs: false, criterion: 7 do\n    scenario"
  end

  test "keeps options already on the spex call" do
    assert {:ok, stamped} = Stamp.stamp(spex(", fail_on_error_logs: false"), 7)
    assert stamped =~ ~s(spex "It is reported", fail_on_error_logs: false, criterion: 7 do)
  end
end
