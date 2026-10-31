defmodule Mix.Tasks.Cms.SpexRunLinkEnvTest do
  @moduledoc """
  Each shard of a run the harness watches joins it as a node of its own (the
  shards inherited the parent's node name and could not all take it), and is
  told it is a shard, so it leaves finishing the run to its runner
  (issue 96d02161).
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cms.Spex

  @options "-hidden -name cms_run_42_7@127.0.0.1 -setcookie c00k1e"

  # Which shard of how many comes from `shards/2`, counted from those that run.
  test "each shard is named for itself" do
    assert [
             {"ELIXIR_ERL_OPTIONS", "-hidden -name cms_run_42_7_s2@127.0.0.1 -setcookie c00k1e"}
           ] = Spex.run_link_env(2, @options)
  end

  test "a run nobody watches adds nothing" do
    assert Spex.run_link_env(1, nil) == []
    assert Spex.run_link_env(1, "+S 4") == []
  end

  # The harness finishes a run once every shard it was told of has exited;
  # told of four when two ran, it never finished.
  test "a suite of fewer files than shards tells each shard how many run" do
    files = ["test/spex/1_a_spex.exs", "test/spex/2_b_spex.exs"]

    assert [{["test/spex/1_a_spex.exs"], 1, one}, {["test/spex/2_b_spex.exs"], 2, two}] =
             Spex.shards(files, "cms_harness_1@127.0.0.1")

    assert one == [{"CMS_RUN_SHARD", "1"}, {"CMS_RUN_SHARDS", "2"}]

    assert {"CMS_RUN_SHARDS", "2"} in two
  end

  test "a run no harness watches gives its shards none" do
    assert [{_, 1, []}] = Spex.shards(["test/spex/1_a_spex.exs"], nil)
  end
end
