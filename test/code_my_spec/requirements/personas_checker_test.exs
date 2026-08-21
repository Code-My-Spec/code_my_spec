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
end
