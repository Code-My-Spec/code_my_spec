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

  test "each shard is named for itself and told it is a shard" do
    assert [
             {"ELIXIR_ERL_OPTIONS", "-hidden -name cms_run_42_7_s2@127.0.0.1 -setcookie c00k1e"},
             {"CMS_RUN_SHARDS", "4"}
           ] = Spex.run_link_env(2, @options)
  end

  test "a run nobody watches adds nothing" do
    assert Spex.run_link_env(1, nil) == []
    assert Spex.run_link_env(1, "+S 4") == []
  end
end
