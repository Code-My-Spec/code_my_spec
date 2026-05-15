defmodule CodeMySpec.Personas.PersonasRepositoryTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Personas.PersonasRepository
  alias CodeMySpec.Repo

  @valid_attrs %{slug: "founder", name: "Founder", headline: "Solo bootstrapper"}

  defp persona_fixture(scope, attrs \\ %{}) do
    {:ok, persona} =
      PersonasRepository.create_persona(scope, Map.merge(@valid_attrs, Map.new(attrs)))

    persona
  end

  describe "create_persona/2" do
    test "inserts a persona scoped to the active project" do
      scope = full_scope_fixture()

      assert {:ok, %Persona{} = persona} =
               PersonasRepository.create_persona(scope, @valid_attrs)

      assert persona.project_id == scope.active_project_id
      assert persona.slug == "founder"
      assert persona.name == "Founder"
      assert persona.persona_type == :proto
    end

    test "returns changeset error on invalid attrs" do
      scope = full_scope_fixture()

      assert {:error, %Ecto.Changeset{}} =
               PersonasRepository.create_persona(scope, %{slug: "", name: ""})
    end

    test "returns :missing_active_project when scope has no active project" do
      scope = full_scope_fixture() |> Map.put(:active_project_id, nil)

      assert {:error, :missing_active_project} =
               PersonasRepository.create_persona(scope, @valid_attrs)
    end

    test "rejects duplicate slug within the same project" do
      scope = full_scope_fixture()
      {:ok, _} = PersonasRepository.create_persona(scope, @valid_attrs)

      assert {:error, %Ecto.Changeset{}} =
               PersonasRepository.create_persona(scope, @valid_attrs)
    end
  end

  describe "list_personas/1" do
    test "returns all personas on the active project ordered by name" do
      scope = full_scope_fixture()
      _b = persona_fixture(scope, %{slug: "b-persona", name: "Beta"})
      _a = persona_fixture(scope, %{slug: "a-persona", name: "Alpha"})
      _c = persona_fixture(scope, %{slug: "c-persona", name: "Charlie"})

      personas = PersonasRepository.list_personas(scope)

      assert Enum.map(personas, & &1.name) == ["Alpha", "Beta", "Charlie"]
    end

    test "excludes personas from other projects" do
      scope = full_scope_fixture()
      other = full_scope_fixture()
      persona_fixture(scope, %{slug: "mine", name: "Mine"})
      persona_fixture(other, %{slug: "theirs", name: "Theirs"})

      [persona] = PersonasRepository.list_personas(scope)
      assert persona.name == "Mine"
    end

    test "returns [] when scope has no active project" do
      scope = full_scope_fixture() |> Map.put(:active_project_id, nil)
      assert PersonasRepository.list_personas(scope) == []
    end
  end

  describe "get_persona_by_slug/2" do
    test "fetches a persona by slug within the active project" do
      scope = full_scope_fixture()
      persona = persona_fixture(scope)

      assert %Persona{} = found = PersonasRepository.get_persona_by_slug(scope, persona.slug)
      assert found.id == persona.id
    end

    test "returns nil for unknown slug" do
      scope = full_scope_fixture()
      assert PersonasRepository.get_persona_by_slug(scope, "nope") == nil
    end

    test "does not return personas from other projects" do
      scope = full_scope_fixture()
      other = full_scope_fixture()
      persona_fixture(other, %{slug: "shared-slug", name: "Theirs"})

      assert PersonasRepository.get_persona_by_slug(scope, "shared-slug") == nil
    end

    test "returns nil when scope has no active project" do
      scope = full_scope_fixture() |> Map.put(:active_project_id, nil)
      assert PersonasRepository.get_persona_by_slug(scope, "anything") == nil
    end
  end

  describe "link_persona_to_story/3" do
    test "links a persona to a story in the same project" do
      scope = full_scope_fixture()
      persona = persona_fixture(scope)
      story = story_fixture(scope, %{criteria: []})

      assert {:ok, link} = PersonasRepository.link_persona_to_story(scope, persona.id, story.id)
      assert link.persona_id == persona.id
      assert link.story_id == story.id
    end

    test "returns :cross_project when the persona belongs to a different project" do
      scope = full_scope_fixture()
      other = full_scope_fixture()
      foreign = persona_fixture(other)
      story = story_fixture(scope, %{criteria: []})

      assert {:error, :cross_project} =
               PersonasRepository.link_persona_to_story(scope, foreign.id, story.id)
    end

    test "returns :cross_project when the story belongs to a different project" do
      scope = full_scope_fixture()
      other = full_scope_fixture()
      persona = persona_fixture(scope)
      foreign_story = story_fixture(other, %{criteria: []})

      assert {:error, :cross_project} =
               PersonasRepository.link_persona_to_story(scope, persona.id, foreign_story.id)
    end

    test "returns :missing_active_project when scope has no active project" do
      scope = full_scope_fixture()
      persona = persona_fixture(scope)
      story = story_fixture(scope, %{criteria: []})
      unscoped = Map.put(scope, :active_project_id, nil)

      assert {:error, :missing_active_project} =
               PersonasRepository.link_persona_to_story(unscoped, persona.id, story.id)
    end
  end

  describe "list_personas_for_story/2" do
    test "returns personas linked to the given story in the active project" do
      scope = full_scope_fixture()
      p1 = persona_fixture(scope, %{slug: "alpha", name: "Alpha"})
      p2 = persona_fixture(scope, %{slug: "beta", name: "Beta"})
      _p3 = persona_fixture(scope, %{slug: "charlie", name: "Charlie"})

      story = story_fixture(scope, %{criteria: []})
      {:ok, _} = PersonasRepository.link_persona_to_story(scope, p1.id, story.id)
      {:ok, _} = PersonasRepository.link_persona_to_story(scope, p2.id, story.id)

      result = PersonasRepository.list_personas_for_story(scope, story.id)

      assert Enum.map(result, & &1.name) == ["Alpha", "Beta"]
    end

    test "returns [] when the story has no linked personas" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})
      persona_fixture(scope)

      assert PersonasRepository.list_personas_for_story(scope, story.id) == []
    end

    test "returns [] when scope has no active project" do
      scope = full_scope_fixture() |> Map.put(:active_project_id, nil)
      assert PersonasRepository.list_personas_for_story(scope, 1) == []
    end
  end

  describe "list_personas_for_project/2" do
    test "returns personas for the active project when project_id matches scope" do
      scope = full_scope_fixture()
      a = persona_fixture(scope, %{slug: "a", name: "A"})
      b = persona_fixture(scope, %{slug: "b", name: "B"})

      result = PersonasRepository.list_personas_for_project(scope, scope.active_project_id)

      assert Enum.map(result, & &1.id) |> Enum.sort() == Enum.sort([a.id, b.id])
    end

    test "returns [] when project_id does not match active scope" do
      scope = full_scope_fixture()
      other = full_scope_fixture()
      persona_fixture(scope)
      persona_fixture(other)

      assert PersonasRepository.list_personas_for_project(scope, other.active_project_id) == []
    end

    test "returns [] when scope has no active project" do
      scope = full_scope_fixture() |> Map.put(:active_project_id, nil)
      assert PersonasRepository.list_personas_for_project(scope, 1) == []
    end
  end

  describe "cascading delete via Repo (verification of FK)" do
    test "deleting a persona removes its persona_stories rows" do
      scope = full_scope_fixture()
      persona = persona_fixture(scope)
      story = story_fixture(scope, %{criteria: []})
      {:ok, link} = PersonasRepository.link_persona_to_story(scope, persona.id, story.id)

      {:ok, _} = PersonasRepository.delete_persona(scope, persona)

      assert Repo.get(CodeMySpec.Personas.PersonaStory, link.id) == nil
    end
  end
end
