defmodule CodeMySpec.Requirements.PersonasCheckerTest do
  @moduledoc """
  `personas_complete` is satisfied when **every** persona on the project has
  research on disk.

  A249095 relaxed this to "at least one," reasoning that a bare DB stub
  sitting beside a fully-researched persona shouldn't hold the requirement
  shut. That traded a graph-gridlock bug for a worse one: an agent could
  create a lightweight persona during Three Amigos (`add_persona` — identity
  and metadata only, no research) and get no signal that research was still
  owed, because some other persona on the project already had it. Story
  559/criterion 5888 is exactly this case. An unresearched persona is
  unfinished work regardless of what else exists on the project.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files
  alias CodeMySpec.Personas
  alias CodeMySpec.Requirements.PersonasChecker

  defp researched!(scope, name, slug) do
    {:ok, persona} = Personas.create_persona(scope, %{name: name, slug: slug, status: :proto})

    for {path, role} <- [
          {Personas.summary_path(slug), :persona_summary},
          {Personas.sources_path(slug), :persona_sources}
        ] do
      {1, _} =
        Files.upsert_files(scope, [
          %{
            path: path,
            role: role,
            mtime: DateTime.utc_now(),
            size: 100,
            fingerprint: "fp-#{slug}-#{role}",
            valid: true,
            validation_errors: %{}
          }
        ])
    end

    persona
  end

  defp stub!(scope, name, slug) do
    {:ok, persona} = Personas.create_persona(scope, %{name: name, slug: slug, status: :proto})
    persona
  end

  describe "complete?/2" do
    test "every persona researched satisfies it" do
      scope = full_scope_fixture()

      researched!(scope, "Gem-Weary Wes", "gem-weary-wes")
      researched!(scope, "Ledger-Minded Mara", "ledger-minded-mara")

      assert {true, _detail} = PersonasChecker.complete?(scope, nil)
    end

    test "a stub sitting beside a researched persona still blocks, and says which" do
      scope = full_scope_fixture()

      researched!(scope, "Gem-Weary Wes", "gem-weary-wes")
      stub!(scope, "Ledger-Minded Mara", "ledger-minded-mara")

      assert {false, detail} = PersonasChecker.complete?(scope, nil)
      assert detail.reason =~ "ledger-minded-mara"
    end

    test "no personas at all is still unsatisfied" do
      scope = full_scope_fixture()

      assert {false, detail} = PersonasChecker.complete?(scope, nil)
      assert detail.reason =~ "No personas"
    end

    test "personas that are all stubs is unsatisfied, and says which" do
      scope = full_scope_fixture()

      stub!(scope, "Ledger-Minded Mara", "ledger-minded-mara")
      stub!(scope, "Rushdown Rhea", "rushdown-rhea")

      assert {false, detail} = PersonasChecker.complete?(scope, nil)
      assert detail.reason =~ "ledger-minded-mara"
      assert detail.reason =~ "rushdown-rhea"
    end
  end

  describe "research written in one checkout, checked from another" do
    test "counts, because a persona belongs to the project and not to a tree" do
      scope = full_scope_fixture()
      writer = %{scope | active_working_copy_id: other_copy(scope, "/tmp/a-worktree")}

      researched!(writer, "Gem-Weary Wes", "gem-weary-wes")

      # The reader is bound to a different checkout — which is what a session
      # gets when `CMS_HARNESS_ID` names one root and the files are written in
      # another. The artifacts exist, are valid, and have been scanned.
      reader = %{scope | active_working_copy_id: other_copy(scope, "/tmp/b-worktree")}

      assert {true, _} = PersonasChecker.complete?(reader, nil), """
      The persona's research is invisible from a scope bound to a different
      checkout, so correct and already-scanned work reports as missing. There is
      no per-checkout meaning to "this project's personas are researched".
      """
    end

    test "a valid copy outranks an invalid one at the same path" do
      scope = full_scope_fixture()

      good = %{scope | active_working_copy_id: other_copy(scope, "/tmp/good-worktree")}
      researched!(good, "Gem-Weary Wes", "gem-weary-wes")

      # The same paths in a second checkout, stale and failing validation. Which
      # row the map keeps must not decide the verdict.
      bad = %{scope | active_working_copy_id: other_copy(scope, "/tmp/stale-worktree")}
      broken!(bad, "gem-weary-wes")

      assert {true, _} = PersonasChecker.complete?(scope, nil),
             "a stale checkout's broken copy decided the verdict for the whole project"
    end

    test "and a persona researched nowhere is still unsatisfied" do
      scope = full_scope_fixture()
      writer = %{scope | active_working_copy_id: other_copy(scope, "/tmp/a-worktree")}

      researched!(writer, "Gem-Weary Wes", "gem-weary-wes")
      stub!(scope, "Rushdown Rhea", "rushdown-rhea")

      assert {false, detail} = PersonasChecker.complete?(scope, nil)
      assert detail.reason =~ "rushdown-rhea"
      refute detail.reason =~ "gem-weary-wes"
    end
  end

  # A second checkout of the same project, minted the way the fixture mints the
  # first: a copy is identified by {project, device, root}, so it needs a
  # machine to belong to.
  defp other_copy(scope, root) do
    {:ok, device} =
      CodeMySpec.Devices.announce(scope, nil, %{hostname: "machine-#{root}", kind: :local})

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil, label: Path.basename(root), device: device)

    {:ok, copy} = CodeMySpec.WorkingCopies.report_root(copy, root)

    copy.id
  end

  defp broken!(scope, slug) do
    {1, _} =
      Files.upsert_files(scope, [
        %{
          path: Personas.sources_path(slug),
          role: :persona_sources,
          mtime: DateTime.utc_now(),
          size: 10,
          fingerprint: "fp-stale-#{slug}",
          valid: false,
          validation_errors: %{"errors" => %{"sources" => "`sources.md` has no entries"}}
        }
      ])
  end
end
