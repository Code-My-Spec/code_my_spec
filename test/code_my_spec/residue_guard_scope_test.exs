defmodule CodeMySpecSpex.ResidueGuardScopeTest do
  @moduledoc """
  The residue guard checks the kinds a spex actually creates.

  `9af4a111`. It asked Hetzner for servers and buckets, concatenated them and
  refused on any `spex-` name — so re-recording the 969/974 *mail* cassettes was
  refused because a drill was holding Hetzner *servers*, with no overlap between
  what it found and what those criteria touch. The drill and the spex suite were
  mutually exclusive by construction, on entirely disjoint infrastructure, and
  the only ways out were to tear down working infrastructure or not record.

  The guard is right in principle and the fix must not overshoot it: a criterion
  whose premise is "this resource exists" has to be the thing that creates it, or
  it passes on residue without creating anything. Only the scope was wrong.

  Kinds are declared rather than derived, because the guard runs once per BEAM
  from a `setup`, before any criterion — it cannot ask what is about to run.
  Undeclared means `:all`, so the safe answer is the one you get without
  thinking about it, and nothing that has not opted in changes behaviour.

  ## Not async, and the credentials are removed rather than checked

  `leaked_spex_resources/1` calls Hetzner the moment its three environment
  variables are set — and they *are* set in the shell a recording session runs
  from, which is exactly where somebody would run the suite next. Branching on
  whether they happen to be present would make this test reach a real provider
  depending on who ran it, and would assert nothing on those machines.

  So the setup takes them away and puts them back, which is deterministic
  everywhere. That write is process-global, hence no `async: true` — the same
  reasoning `CodeMySpec.EnvironmentsTest` uses for rewriting `PATH`.
  """

  use ExUnit.Case

  alias CodeMySpecSpex.Fixtures

  @credentials ~w(HETZNER_API_TOKEN HETZNER_S3_ACCESS_KEY_ID HETZNER_S3_SECRET_ACCESS_KEY)

  setup do
    saved = Map.new(@credentials, &{&1, System.get_env(&1)})
    Enum.each(@credentials, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  describe "spex_named/1" do
    test "keeps only spex- names, because everything else is real infrastructure" do
      names = ["spex-story972-criterion8034", "codemyspec-prod", "spex-bucket-1", "sams-site"]

      assert Fixtures.spex_named(names) == ["spex-story972-criterion8034", "spex-bucket-1"]
    end

    test "handles the shapes a provider actually returns" do
      assert Fixtures.spex_named([]) == []
      assert Fixtures.spex_named([nil]) == []
      assert Fixtures.spex_named(["spex-x", :"spex-y"]) == ["spex-x", :"spex-y"]
    end
  end

  describe "leaked_spex_resources/1" do
    test "asks nobody, and reports nothing, without credentials" do
      assert Fixtures.leaked_spex_resources() == []
      assert Fixtures.leaked_spex_resources(:all) == []
      assert Fixtures.leaked_spex_resources([:buckets]) == []
    end

    # The contract the @moduletag relies on. A spex writing
    # `spex_resources: :buckets` rather than `[:buckets]` is the obvious slip,
    # and it should mean what it says rather than silently checking nothing.
    test "accepts a kind list, a bare kind, and :all" do
      for kinds <- [:all, :servers, :buckets, [:servers], [:buckets], [:servers, :buckets]] do
        assert Fixtures.leaked_spex_resources(kinds) == []
      end
    end
  end
end
