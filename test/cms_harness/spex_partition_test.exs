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

  alias ClientUtils.Harness.Onboarding
  alias CmsHarness.AnalyzerEnv

  @cwd "/src/app"

  defp partition(env), do: env |> List.keyfind("MIX_TEST_PARTITION", 0) |> elem(1)

  describe "partition_for/2" do
    test "spex does not share exunit's database" do
      refute Onboarding.partition_name(@cwd) <> "s" ==
               Onboarding.partition_name(@cwd)
    end

    test "exunit keeps the partition it already had" do
      assert Onboarding.partition_name(@cwd) == Onboarding.partition_name(@cwd)

      assert Onboarding.partition_name(@cwd) == Onboarding.partition_name(@cwd),
             "only spex moves; anything else changing would orphan a migrated database"
    end

    test "each is still stable across calls and per working copy" do
      assert Onboarding.partition_name(@cwd) <> "s" ==
               Onboarding.partition_name(@cwd) <> "s"

      refute Onboarding.partition_name(@cwd) <> "s" ==
               Onboarding.partition_name("/src/other") <> "s"
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
