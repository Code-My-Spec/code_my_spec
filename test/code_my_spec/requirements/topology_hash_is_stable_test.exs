defmodule CodeMySpec.Requirements.TopologyHashIsStableTest do
  @moduledoc """
  Whether two identical reads of the same project hash to the same topology.

  `reproject_topology/3` skips the edge write when the hash matches what it
  cached, and edges are the expensive half — 123,236 rows deleted and
  reinserted on this project. Measured on dev: five drains since 02:17 wrote
  726,011 of 920,417 rows between them, every one a full edge replace, on
  observations that changed nothing `topology_parts/2` hashes.

  Either the cache is not being consulted, or the hash moves when its inputs do
  not. This asks the second question directly, which is the cheaper of the two
  to answer and the one nothing has ever checked.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.Requirements.{Freshness, Preloader}

  setup :register_log_in_setup_account
  setup :setup_active_project

  describe "the same project, read twice" do
    test "hashes to the same topology both times", %{scope: scope} do
      CodeMySpec.ComponentsFixtures.component_fixture(scope)
      config = CodeMySpec.Configurations.get_or_create(scope)

      {:ok, first} = Preloader.load(scope)
      {:ok, second} = Preloader.load(scope)

      parts_one = Freshness.topology_parts(first, config)
      parts_two = Freshness.topology_parts(second, config)

      assert parts_one == parts_two,
             """
             Two identical reads produced different topology digests, so the
             gate on the edge write can never hold and every drain that reaches
             it replaces the whole edge set.

             `topology_parts/2` reports its three digests separately precisely
             so the mover can be named:

               components: #{inspect(parts_one.components)} vs #{inspect(parts_two.components)}
               stories:    #{inspect(parts_one.stories)} vs #{inspect(parts_two.stories)}
               config:     #{inspect(parts_one.config)} vs #{inspect(parts_two.config)}
             """

      assert Freshness.topology(first, config) == Freshness.topology(second, config)
    end
  end
end
