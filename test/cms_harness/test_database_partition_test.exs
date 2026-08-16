defmodule CmsHarness.TestDatabasePartitionTest do
  @moduledoc """
  The analyzer resolves the partition onboarding recorded, rather than one it
  derives.

  This is the consumer half of story 891's rule 4, and it is the half nothing
  tested. The spex can reach `ClientUtils.Harness.Onboarding` and prove the
  resolver reads; it cannot reach `CmsHarness`, so it cannot prove the analyzer
  *uses* the resolver. That gap is exactly where the defect lived: onboarding
  recorded a partition, `TestDatabase` digested the cwd, and the two agreed only
  because one algorithm had been written twice (acaf8035).

  Every assertion here uses a recorded value no digest could return, so passing
  requires reading. A test that records a plausible partition passes whether the
  consumer reads it or recomputes it.

  There is no derive-on-miss path to test, deliberately. A fallback would keep
  both mechanisms alive for exactly the copies nobody had onboarded — silently,
  which is how the first pair survived. An un-onboarded copy refuses and names the
  command that fixes it.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.TestDatabase

  # Not 8 hex characters after an `h`, so `partition_name/1` cannot produce it.
  @recorded "recorded-not-derived"

  setup do
    root = CodeMySpec.TempFile.dir("partition")
    File.mkdir_p!(Path.join(root, ".claude"))
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  defp record(root, partition) do
    File.write!(
      Path.join([root, ".claude", "settings.local.json"]),
      Jason.encode!(%{"env" => %{"MIX_TEST_PARTITION" => partition}})
    )
  end

  describe "partition_for/1" do
    test "returns the recorded partition", %{root: root} do
      record(root, @recorded)

      assert TestDatabase.partition_for(root) == @recorded
    end

    test "refuses a copy with nothing recorded, and names the remedy", %{root: root} do
      assert_raise RuntimeError, ~r/has not been onboarded.*mix harness\.onboard/s, fn ->
        TestDatabase.partition_for(root)
      end
    end

    test "refuses a settings file that names no partition", %{root: root} do
      File.write!(
        Path.join([root, ".claude", "settings.local.json"]),
        Jason.encode!(%{"env" => %{"ANTHROPIC_BASE_URL" => "http://localhost:4004"}})
      )

      assert_raise RuntimeError, ~r/has not been onboarded/, fn ->
        TestDatabase.partition_for(root)
      end
    end
  end

  describe "env/3" do
    test "hands the analyzer the recorded partition", %{root: root} do
      record(root, @recorded)

      assert [{"MIX_TEST_PARTITION", @recorded}] = TestDatabase.env(%{cwd: root})
    end

    test "spex still gets its own database, suffixed from the recorded name",
         %{root: root} do
      record(root, @recorded)

      assert [{"MIX_TEST_PARTITION", @recorded <> "s"}] ==
               TestDatabase.env(%{cwd: root}, [], "spex")
    end
  end
end
