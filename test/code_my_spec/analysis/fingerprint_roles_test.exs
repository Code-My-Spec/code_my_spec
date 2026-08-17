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

  defp check_ledger(fingerprint) do
    [
      file("lib/app.ex", :implementation, "impl-1"),
      file(".code_my_spec/credo_checks/framework/x.ex", :credo_check, fingerprint)
    ]
  end

  describe "every role is classified" do
    # The one that closes the class rather than an instance.
    #
    # Per-source allow-lists under-approximate silently: the source keeps
    # reporting fresh while its findings describe content that has changed.
    # Splitting every role into code-or-document makes the omission impossible
    # to reach without failing here first.
    test "no role is missing from both lists" do
      unclassified =
        ProjectFile.roles() -- (Fingerprint.code_roles() ++ Fingerprint.document_roles())

      assert unclassified == [],
             """
             These file roles feed no analyzer and are declared no document:

             #{Enum.map_join(unclassified, "\n", &("  " <> inspect(&1)))}

             Put each in `@code_roles` if an analyzer reads it, `@document_roles`
             if none does. Leaving it out is not neutral — a role absent from
             every source's set cannot invalidate anything, so an analyzer holds
             findings about a file it can no longer notice changing, and reports
             them as current (b1340e13).
             """
    end

    test "no list names a role that does not exist" do
      phantom =
        Fingerprint.code_roles() ++ Fingerprint.document_roles()

      assert phantom -- ProjectFile.roles() == [],
             "a classified role that File.roles/0 does not define is dead weight"
    end

    test "the two lists do not overlap" do
      overlap =
        MapSet.intersection(
          MapSet.new(Fingerprint.code_roles()),
          MapSet.new(Fingerprint.document_roles())
        )

      assert MapSet.equal?(overlap, MapSet.new()), "a role is either read or it is not"
    end
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

    # The same omission, one file over, found while fixing the first.
    test "a changed credo check changes the fingerprint" do
      roles = Fingerprint.roles("credo")

      refute Fingerprint.compute(check_ledger("before"), roles) ==
               Fingerprint.compute(check_ledger("after"), roles),
             """
             `.code_my_spec/credo_checks/**/*.ex` are Elixir modules credo loads.
             Editing one changes credo's verdicts, so a fingerprint blind to them
             lets credo report findings produced by rules that no longer exist.
             """
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
