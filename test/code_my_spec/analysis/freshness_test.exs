defmodule CodeMySpec.Analysis.FreshnessTest do
  @moduledoc """
  "Is this analyzer current for today's code" as a projection of two events,
  instead of a hash of every file on every read.

  The question was being answered by `Fingerprint.current/2` — the whole file
  table for the checkout, ~5,100 rows, hashed per source — on every promote
  attempt and every graph pass. It is not a question about now. It is a question
  about a run finishing and a file it reads changing, and which came last.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Analysis.Fingerprint
  alias CodeMySpec.Analysis.Freshness
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, device: device_fixture(scope), root: "/a/checkout")

    %{scope: scope, copy: copy}
  end

  describe "what a role stales" do
    test "code stales every analyzer that reads it" do
      # The inverse of `@source_roles`, so it cannot disagree with the
      # fingerprints about which files feed which source.
      assert Fingerprint.sources_for_role(:implementation) |> Enum.sort() ==
               ~w(compiler credo exunit spex)

      assert Fingerprint.sources_for_role(:test) |> Enum.sort() == ~w(compiler credo exunit spex)
    end

    test "a spex file stales credo and spex, not compiler or exunit" do
      # `mix compile` and `mix test` do not read `*_spex.exs`.
      assert Fingerprint.sources_for_role(:bdd_spec) |> Enum.sort() == ~w(credo spex)
    end

    test "credo's own configuration stales only credo" do
      assert Fingerprint.sources_for_role(:credo_exs) == ["credo"]
      assert Fingerprint.sources_for_role(:credo_check) == ["credo"]
    end

    test "a document stales nothing" do
      # The reason a persona summary or a knowledge doc landing has never made
      # an analyzer stale, and must not start.
      assert Fingerprint.sources_for_role(:persona_summary) == []
      assert Fingerprint.sources_for_role(:knowledge) == []
      assert Fingerprint.sources_for_role(:spec) == []
    end
  end

  describe "the projection" do
    test "knows nothing until something is projected", %{copy: copy} do
      assert Freshness.known(copy.id) == %{}

      # Absence is unknown, not stale. A reader falls back to the comparison
      # rather than guessing, which is what makes this safe without a backfill.
      assert Freshness.known(copy.id, "credo") == nil
    end

    test "a completed run makes its source fresh", %{copy: copy} do
      :ok = Freshness.mark_fresh(copy.id, "credo", nil)

      assert Freshness.known(copy.id) == %{"credo" => true}
      assert Freshness.known(copy.id, "credo") == true
    end

    test "a code file stales every source that reads it", %{copy: copy} do
      for source <- ~w(compiler credo exunit spex),
          do: :ok = Freshness.mark_fresh(copy.id, source)

      :ok = Freshness.stale_for_roles(copy.id, [:implementation], "lib/thing.ex")

      assert Freshness.known(copy.id) == %{
               "compiler" => false,
               "credo" => false,
               "exunit" => false,
               "spex" => false
             }
    end

    test "a spex file leaves compiler and exunit alone", %{copy: copy} do
      for source <- ~w(compiler credo exunit spex),
          do: :ok = Freshness.mark_fresh(copy.id, source)

      :ok = Freshness.stale_for_roles(copy.id, [:bdd_spec], "test/x_spex.exs")

      assert Freshness.known(copy.id) == %{
               "compiler" => true,
               "credo" => false,
               "exunit" => true,
               "spex" => false
             }
    end

    test "a document leaves everything fresh", %{copy: copy} do
      for source <- ~w(compiler credo exunit spex),
          do: :ok = Freshness.mark_fresh(copy.id, source)

      :ok = Freshness.stale_for_roles(copy.id, [:knowledge, :persona_summary], ".cms/notes.md")

      assert Freshness.known(copy.id) |> Map.values() |> Enum.all?()
    end

    test "staling records what took it away", %{copy: copy} do
      :ok = Freshness.mark_fresh(copy.id, "credo")
      :ok = Freshness.stale_for_roles(copy.id, [:implementation], "lib/culprit.ex")

      row = CodeMySpec.Repo.get_by(Freshness, working_copy_id: copy.id, source: "credo")

      # A source that is stale with no explanation is the shape that costs time
      # to diagnose; the gate's refusal can name the file.
      refute row.fresh
      assert row.staled_by == "lib/culprit.ex"
      assert row.staled_at
    end

    test "a run landing after a change makes it fresh again", %{copy: copy} do
      :ok = Freshness.mark_fresh(copy.id, "spex")
      :ok = Freshness.stale_for_roles(copy.id, [:implementation], "lib/thing.ex")
      refute Freshness.known(copy.id, "spex")

      :ok = Freshness.mark_fresh(copy.id, "spex")

      assert Freshness.known(copy.id, "spex")

      row = CodeMySpec.Repo.get_by(Freshness, working_copy_id: copy.id, source: "spex")

      refute row.staled_at,
             "going fresh has to clear what staled it, or the row contradicts itself"
    end

    test "staling an unprojected source leaves it unknown", %{copy: copy} do
      # Not the same as asserting it stale. A source nothing has projected has
      # no baseline to be stale against, and claiming one would be a guess in
      # the direction that reads as a false answer.
      :ok = Freshness.stale_for_roles(copy.id, [:implementation], "lib/thing.ex")

      assert Freshness.known(copy.id) == %{}
    end
  end
end
