defmodule CodeMySpec.Requirements.PersonasCheckerTest do
  @moduledoc """
  `personas_complete` is satisfied by **one** researched persona, which is what
  its description has always promised and not what it did.

  The checker rejected any persona with a gap and required the resulting list to
  be empty, so every persona on the project had to be complete. A project with
  one fully researched persona and two bare stubs stayed unsatisfied for ever.
  Measured on Broken Oaths: "Gem-Weary Wes" had a record, a well-cited
  `summary.md` and a `sources.md`; "Ledger-Minded Mara" and "Rushdown Rhea" were
  DB stubs with no files. `get_next_requirement` kept returning
  `personas_complete`, so an agent that did exactly the documented work was told
  it had not done it — and the only way to find out why was to read the checker.

  That is the expensive direction for a gate to be wrong in. Asking for more
  than the contract says means the work an agent was told to do never opens the
  gate.

  There was no unit test here, which is how the contradiction survived: the one
  spex that covers this requirement uses a single persona, where "all complete"
  and "at least one complete" cannot be told apart.
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
    test "one researched persona satisfies it even when stubs sit beside it" do
      scope = full_scope_fixture()

      researched!(scope, "Gem-Weary Wes", "gem-weary-wes")
      stub!(scope, "Ledger-Minded Mara", "ledger-minded-mara")
      stub!(scope, "Rushdown Rhea", "rushdown-rhea")

      assert {true, _detail} = PersonasChecker.complete?(scope, nil),
             "a bare stub held this requirement shut while a fully researched " <>
               "persona sat beside it, so the documented work never opened the gate"
    end

    # Satisfying quietly would trade one invisible problem for another: the
    # requirement passes and nobody learns the project carries empty personas.
    test "the stubs it no longer blocks on are still named" do
      scope = full_scope_fixture()

      researched!(scope, "Gem-Weary Wes", "gem-weary-wes")
      stub!(scope, "Ledger-Minded Mara", "ledger-minded-mara")

      assert {true, detail} = PersonasChecker.complete?(scope, nil)
      assert detail.status =~ "ledger-minded-mara"
    end

    test "no personas at all is still unsatisfied" do
      scope = full_scope_fixture()

      assert {false, detail} = PersonasChecker.complete?(scope, nil)
      assert detail.reason =~ "No personas"
    end

    # The half that did not change. "At least one" is not "none" — a project
    # whose every persona is a stub has done no research, and this is the case
    # the requirement exists to catch.
    test "personas that are all stubs is unsatisfied, and says which" do
      scope = full_scope_fixture()

      stub!(scope, "Ledger-Minded Mara", "ledger-minded-mara")
      stub!(scope, "Rushdown Rhea", "rushdown-rhea")

      assert {false, detail} = PersonasChecker.complete?(scope, nil)
      assert detail.reason =~ "ledger-minded-mara"
      assert detail.reason =~ "rushdown-rhea"
    end
  end
end
