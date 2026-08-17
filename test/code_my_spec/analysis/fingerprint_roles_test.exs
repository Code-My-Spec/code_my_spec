defmodule CodeMySpec.Analysis.FingerprintRolesTest do
  @moduledoc """
  A source's fingerprint has to span the files that source actually reads.

  The fingerprint is what `Analysis.fresh_sources/2` compares against a run's
  `input_fingerprint` to decide whether findings are current. If a role an
  analyzer reads is missing from its role set, editing a file of that role
  cannot change the fingerprint — so the source reports *fresh* while holding
  findings about the version before the edit, and the stop hook drops the
  "stale" marker that would have told the reader the data was superseded.

  Observed 2026-08-17: five imperative-`case` findings in `_spex.exs` files were
  fixed at 06:58:44 and still presented as current at 07:02:08, with no
  staleness note, against a credo run that completed at 06:58:18. Nothing had
  gone wrong with clearing — the reconcile at 07:02:18 dropped all five. The
  fault was upstream, in a fingerprint that could not see the edit.

  These assert behaviour (the hash moves) rather than the contents of
  `@source_roles`, so they stay meaningful if the roles are ever restructured.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.Fingerprint
  alias CodeMySpec.Files.File, as: ProjectFile

  defp file(path, role, fingerprint),
    do: %ProjectFile{path: path, role: role, fingerprint: fingerprint}

  defp ledger(spex_fingerprint) do
    [
      file("lib/app.ex", :implementation, "impl-1"),
      file("test/app_test.exs", :test, "test-1"),
      file("test/spex/1017_x/criterion_1_spex.exs", :bdd_spec, spex_fingerprint)
    ]
  end

  describe "credo" do
    test "a changed spex file changes the fingerprint" do
      roles = Fingerprint.roles("credo")

      refute Fingerprint.compute(ledger("before"), roles) ==
               Fingerprint.compute(ledger("after"), roles),
             """
             credo lints test/spex/**/*_spex.exs — `.credo.exs` includes `test/`,
             and this project ships checks written only for those files. A
             fingerprint blind to them lets credo report fresh while holding
             findings about the previous version of the file.
             """
    end

    test "spex files are part of the input, not merely tolerated" do
      assert :bdd_spec in Fingerprint.roles("credo")
    end
  end

  describe "spex" do
    test "a changed spex file changes the fingerprint" do
      roles = Fingerprint.roles("spex")

      refute Fingerprint.compute(ledger("before"), roles) ==
               Fingerprint.compute(ledger("after"), roles)
    end
  end

  describe "sources that do not read spex files" do
    # `mix compile` does not compile test files and `mix test` does not run
    # `*_spex.exs` — that is a separate task with its own pattern. Adding the
    # role to these would make every spex edit invalidate two suites that
    # cannot have been affected by it, which is a slower loop for no signal.
    test "a changed spex file leaves compiler and exunit fingerprints alone" do
      for source <- ["compiler", "exunit"] do
        roles = Fingerprint.roles(source)

        assert Fingerprint.compute(ledger("before"), roles) ==
                 Fingerprint.compute(ledger("after"), roles),
               "#{source} does not read *_spex.exs and should not be invalidated by one"
      end
    end
  end
end
