defmodule CodeMySpec.Analysis.CoverageTest do
  @moduledoc """
  What an analyzer looked at, and whether it still holds.

  The fact this table adds is the one that has never existed: *this file was
  clean at this content*. `problems.file_fingerprint` already covers the other
  half — a finding whose file moved is dropped by `reject_superseded/1` — but a
  file with no problems and a file nobody analysed have been the same shape, no
  rows, and `tests_passing` reads `count == 0` as clean.

  So the assertions that matter here are the ones that keep those apart.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.Coverage
  alias CodeMySpec.Files
  alias CodeMySpec.Harnesses

  setup do
    scope = full_scope_fixture()
    {:ok, harness} = Harnesses.issue(scope, nil, label: "a working copy")
    %{scope: %{scope | active_harness_id: harness.id}}
  end

  defp put_file(scope, path, fingerprint, role \\ :implementation) do
    {_n, _} =
      Files.upsert_files(scope, [
        %{
          path: path,
          role: role,
          fingerprint: fingerprint,
          mtime: DateTime.utc_now(),
          size: 10
        }
      ])

    scope |> Files.list_files() |> Enum.find(&(&1.path == path))
  end

  describe "unanalyzed_files/2 — the fact that did not exist" do
    test "a file nobody has analysed is named", %{scope: scope} do
      file = put_file(scope, "lib/a.ex", "fp-a")

      assert [%{id: id}] = Coverage.unanalyzed_files(scope, "credo")
      assert id == file.id
    end

    test "a file that has been analysed is not", %{scope: scope} do
      file = put_file(scope, "lib/a.ex", "fp-a")
      Coverage.record(scope, "credo", [{file.id, "fp-a"}])

      assert Coverage.unanalyzed_files(scope, "credo") == []
    end

    # The distinction the whole table exists for.
    test "clean and unlooked-at are different answers", %{scope: scope} do
      looked = put_file(scope, "lib/looked.ex", "fp-1")
      _unlooked = put_file(scope, "lib/unlooked.ex", "fp-2")

      Coverage.record(scope, "credo", [{looked.id, "fp-1"}])

      assert [%{path: "lib/unlooked.ex"}] = Coverage.unanalyzed_files(scope, "credo"),
             "without this, both files are `count == 0` and both read as clean"
    end

    # Roles are per source, so a file that feeds one analyzer does not make
    # another incomplete.
    #
    # The example used to be a `:bdd_spec` against credo, on the belief that
    # credo does not read spex files. It does — `.credo.exs` includes `test/`,
    # and the project ships checks written only for `_spex.exs`. That belief
    # cost a stop hook presenting fixed credo findings as current, because
    # editing a spex file could not move credo's fingerprint (`b1340e13`).
    # `:spec` is a genuine non-input: a markdown spec document feeds neither.
    test "only files whose role feeds the source count", %{scope: scope} do
      put_file(scope, ".code_my_spec/spec/x.md", "fp-d", :spec)

      assert Coverage.unanalyzed_files(scope, "credo") == [],
             "a spec document is not a credo input"

      assert Coverage.unanalyzed_files(scope, "spex") == [],
             "nor a spex input"
    end

    test "a spex file is an input to both credo and spex", %{scope: scope} do
      put_file(scope, "test/spex/x_spex.exs", "fp-s", :bdd_spec)

      assert [%{path: "test/spex/x_spex.exs"}] = Coverage.unanalyzed_files(scope, "spex")

      assert [%{path: "test/spex/x_spex.exs"}] = Coverage.unanalyzed_files(scope, "credo"),
             "credo lints test/spex/**/*_spex.exs, so an unread one leaves credo " <>
               "incomplete — the omission that let fixed findings read as current"
    end
  end

  describe "stale_files/2 — which ones moved" do
    test "a file whose content changed since it was read is named", %{scope: scope} do
      file = put_file(scope, "lib/a.ex", "fp-old")
      Coverage.record(scope, "credo", [{file.id, "fp-old"}])

      put_file(scope, "lib/a.ex", "fp-new")

      assert [%{path: "lib/a.ex"}] = Coverage.stale_files(scope, "credo"),
             "naming the file is what the stop hook has never been able to do"
    end

    test "a file that has not moved is not", %{scope: scope} do
      file = put_file(scope, "lib/a.ex", "fp-1")
      Coverage.record(scope, "credo", [{file.id, "fp-1"}])

      assert Coverage.stale_files(scope, "credo") == []
    end
  end

  describe "fresh?/2 needs both halves" do
    test "covered and unchanged is fresh", %{scope: scope} do
      file = put_file(scope, "lib/a.ex", "fp-1")
      Coverage.record(scope, "credo", [{file.id, "fp-1"}])

      assert Coverage.fresh?(scope, "credo")
    end

    test "a moved file is not fresh", %{scope: scope} do
      file = put_file(scope, "lib/a.ex", "fp-1")
      Coverage.record(scope, "credo", [{file.id, "fp-1"}])
      put_file(scope, "lib/a.ex", "fp-2")

      refute Coverage.fresh?(scope, "credo")
    end

    # The half that is easy to leave out, and the one that would reintroduce
    # absence-as-good-news: everything it read is unchanged, and it has never
    # read half the project.
    test "an unread file is not fresh even though nothing moved", %{scope: scope} do
      read = put_file(scope, "lib/read.ex", "fp-1")
      _never = put_file(scope, "lib/never.ex", "fp-2")

      Coverage.record(scope, "credo", [{read.id, "fp-1"}])

      refute Coverage.fresh?(scope, "credo"),
             "covered-and-unchanged alone calls a source fresh that has never " <>
               "seen half the project"
    end
  end

  describe "record/4" do
    test "upserts rather than accumulating", %{scope: scope} do
      file = put_file(scope, "lib/a.ex", "fp-1")

      Coverage.record(scope, "credo", [{file.id, "fp-1"}])
      Coverage.record(scope, "credo", [{file.id, "fp-2"}])

      put_file(scope, "lib/a.ex", "fp-2")

      assert Coverage.stale_files(scope, "credo") == [],
             "the second record replaced the first rather than adding a row"
    end

    test "sources are recorded independently", %{scope: scope} do
      file = put_file(scope, "lib/a.ex", "fp-1")
      Coverage.record(scope, "credo", [{file.id, "fp-1"}])

      assert Coverage.fresh?(scope, "credo")
      refute Coverage.fresh?(scope, "exunit"), "exunit has not read it"
    end

    # A row whose fingerprint is unknown asserts nothing and would reintroduce
    # the ambiguity the table removes.
    test "an entry with no fingerprint is not recorded", %{scope: scope} do
      file = put_file(scope, "lib/a.ex", "fp-1")

      Coverage.record(scope, "credo", [{file.id, nil}, {file.id, ""}])

      assert [%{path: "lib/a.ex"}] = Coverage.unanalyzed_files(scope, "credo")
    end
  end
end
