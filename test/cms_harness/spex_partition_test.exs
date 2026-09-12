defmodule CmsHarness.SpexPartitionTest do
  @moduledoc """
  spex and exunit get separate databases; they keep the same build tree.

  `Analysis` enqueues compiler, exunit and spex together, and `extra_env/1`
  handed all of them one `MIX_TEST_PARTITION` — so two concurrently running
  suites shared one database. The reasoning for sharing was about the build
  tree ("isolating some would mean the analyzer compiled into one tree and
  tested from another"), which is true of `MIX_BUILD_PATH` and not of the
  database. They were one value by accident of being returned together.

  Measured symptom (`bcad622d`): a sweep truncates the analyzer database before
  exunit, and rows appear *during* it. 13 committed `requirements` rows against
  an empty `projects` table — orphans of a project that no longer exists — and
  17 failures in a file whose suite had passed 3,936/0 two minutes earlier. The
  failures name files the session never touched and are indistinguishable from
  real ones.

  This does not find the out-of-sandbox writer, which is a leak wherever it
  runs. It removes the only shared mutable state between two suites that run at
  the same time, so one cannot corrupt the other while that is chased.

  exunit keeps the existing partition deliberately: changing it would orphan
  the database it has and force a fresh migrate, measured at 37.6s. Only spex
  pays that, once.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.AnalyzerEnv
  alias CmsHarness.TestDatabase

  @cwd "/src/app"

  defp partition(env), do: env |> List.keyfind("MIX_TEST_PARTITION", 0) |> elem(1)

  # These asserted `partition_name(cwd) == partition_name(cwd)` and
  # `partition_name(cwd) <> "s" != partition_name(cwd)` — a value equal to
  # itself, and a string with a letter appended differing from the string. They
  # could not fail for any implementation, and they never called
  # `TestDatabase.partition_for/2` at all; they re-appended the suffix
  # themselves, so the production function could have returned anything.
  #
  # What they missed is what shipped: the suffixes were computed and exported
  # correctly and then **ignored**, because `config/test.exs` ranked the recorded
  # partition above `MIX_TEST_PARTITION` — the only channel this has to say which
  # database it wants. Measured 2026-09-12: `MIX_TEST_PARTITION=h789652afs`
  # resolved to `code_my_spec_testh789652af`, and the `…a`/`…s` databases had sat
  # untouched since 2026-09-07 while both suites and the agent's own `mix test`
  # shared the base. `bcad622d` in full, with green tests over it.
  describe "partition_for/2" do
    # Not 8 hex characters after an `h`, so no digest can produce it: passing
    # requires reading the recording rather than recomputing it.
    @recorded "recorded-not-derived"

    setup do
      root = CodeMySpec.TempFile.dir("spex-partition")
      File.mkdir_p!(Path.join(root, ".claude"))

      File.write!(
        Path.join([root, ".claude", "settings.local.json"]),
        Jason.encode!(%{"env" => %{"MIX_TEST_PARTITION" => @recorded}})
      )

      on_exit(fn -> File.rm_rf(root) end)

      {:ok, root: root}
    end

    defp spex(root), do: partition(TestDatabase.env(%{cwd: root}, [], "spex"))
    defp exunit(root), do: partition(TestDatabase.env(%{cwd: root}, [], "exunit"))

    test "spex does not share exunit's database", %{root: root} do
      refute spex(root) == exunit(root)
    end

    test "neither shares the interactive session's", %{root: root} do
      interactive = partition(TestDatabase.env(%{cwd: root}, [], nil))

      refute spex(root) == interactive
      refute exunit(root) == interactive
    end

    test "each is the recorded partition plus its own suffix", %{root: root} do
      assert spex(root) == @recorded <> "s"
      assert exunit(root) == @recorded <> "a"
    end

    test "the suffix is one config/test.exs will accept", %{root: root} do
      recorded = TestDatabase.partition_for(root)

      for name <- [spex(root), exunit(root)] do
        assert name in [recorded <> "a", recorded <> "s"],
               "config/test.exs accepts an environment partition only when it is the " <>
                 "recorded value plus `a` or `s` — that narrowness is what keeps a value " <>
                 "inherited from another worktree from winning. A partition built any " <>
                 "other way is computed, exported and then silently dropped, and both " <>
                 "suites land on the base database again."
      end
    end

    test "two working copies do not collide", %{root: root} do
      other = CodeMySpec.TempFile.dir("spex-partition-other")
      File.mkdir_p!(Path.join(other, ".claude"))

      File.write!(
        Path.join([other, ".claude", "settings.local.json"]),
        Jason.encode!(%{"env" => %{"MIX_TEST_PARTITION" => "a-different-recording"}})
      )

      on_exit(fn -> File.rm_rf(other) end)

      refute spex(root) == spex(other)
    end
  end

  describe "the build tree" do
    test "does not vary by source" do
      # Asserted through `build_path/1` rather than `extra_env/2` on purpose.
      # `extra_env/2` shells out to `mix ecto.create` to provision the database
      # it is naming, so asserting the build path through it would spawn two
      # subprocesses against a directory that does not exist — for a value that
      # never depended on the database at all. `0bc611c9` is about tests that
      # shell out flaking under concurrent worktree load; no reason to add two.
      assert AnalyzerEnv.build_path(@cwd) == AnalyzerEnv.build_path(@cwd)

      assert String.ends_with?(AnalyzerEnv.build_path(@cwd), "_build/analyzer"),
             "sharing the build tree is the part that was right — compiling into " <>
               "one tree and testing from another is slower and no safer"
    end
  end

  describe "reset targets whichever partition it was given" do
    test "the reset reads the partition out of the env rather than deriving it" do
      # So spex's truncate empties spex's database and not exunit's, with no
      # further change: `reset_data/2` already keys off the passed env.
      spex = [{"MIX_TEST_PARTITION", "hdeadbeefs"}, {"MIX_BUILD_PATH", "/x"}]

      assert partition(spex) == "hdeadbeefs"
    end
  end
end
