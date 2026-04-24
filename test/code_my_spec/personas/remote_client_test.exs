defmodule CodeMySpec.Personas.RemoteClientTest do
  @moduledoc """
  Tests for Personas.RemoteClient — focus is the write-through contract:
  every successful mutation on the server must also land in the local DB so
  `PersonasChecker.complete?/2` sees CLI-initiated writes without waiting for
  a background `RemoteSync` pull.

  HTTP is stubbed with a Req plug — no cassette needed since we're asserting
  on DB side-effects, not wire-format fidelity.
  """

  use CodeMySpecTest.DataCase

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Personas.PersonaStory
  alias CodeMySpec.Personas.RemoteClient
  alias CodeMySpec.Repo

  setup do
    account = account_fixture()

    scope =
      full_scope_fixture()
      |> Map.put(:active_account, account)
      |> Map.put(:active_account_id, account.id)

    {:ok, scope: scope, account_id: account.id}
  end

  # ---------------------------------------------------------------------------
  # create_persona — write-through on success
  # ---------------------------------------------------------------------------

  describe "create_persona/3" do
    test "upserts the returned persona into the local DB on 201",
         %{scope: scope, account_id: account_id} do
      server_persona = %{
        "id" => "11111111-1111-1111-1111-111111111111",
        "slug" => "founder",
        "name" => "Founder",
        "headline" => "Solo founder",
        "persona_type" => "proto",
        "account_id" => account_id,
        "inserted_at" => "2026-04-24T12:00:00Z",
        "updated_at" => "2026-04-24T12:00:00Z"
      }

      plug = stub_response(201, %{"data" => server_persona})

      assert {:ok, persona} =
               RemoteClient.create_persona(
                 scope,
                 %{slug: "founder", name: "Founder"},
                 plug: plug,
                 token: "test"
               )

      # Server-returned record is what the caller gets back.
      assert persona.id == server_persona["id"]
      assert persona.slug == "founder"

      # Write-through: local DB now holds the persona.
      local = Repo.get(Persona, server_persona["id"])
      assert local
      assert local.slug == "founder"
      assert local.account_id == account_id
      assert local.persona_type == :proto
    end

    test "does NOT touch local DB when server returns 422", %{scope: scope} do
      plug = stub_response(422, %{"errors" => %{"slug" => ["has already been taken"]}})

      before_count = Repo.aggregate(Persona, :count)

      assert {:error, %Ecto.Changeset{valid?: false}} =
               RemoteClient.create_persona(
                 scope,
                 %{slug: "bad", name: "Bad"},
                 plug: plug,
                 token: "test"
               )

      assert Repo.aggregate(Persona, :count) == before_count
    end

    test "returns :missing_active_account on 401 without touching local DB", %{scope: scope} do
      plug = stub_response(401, %{"error" => "missing_active_account"})

      before_count = Repo.aggregate(Persona, :count)

      assert {:error, :missing_active_account} =
               RemoteClient.create_persona(
                 scope,
                 %{slug: "x", name: "X"},
                 plug: plug,
                 token: "test"
               )

      assert Repo.aggregate(Persona, :count) == before_count
    end
  end

  # ---------------------------------------------------------------------------
  # update_persona — write-through replaces local row
  # ---------------------------------------------------------------------------

  describe "update_persona/4" do
    test "replaces the local row with the server-returned version",
         %{scope: scope, account_id: account_id} do
      persona = insert_local_persona(account_id, slug: "founder", name: "Old Name")

      server_persona = %{
        "id" => persona.id,
        "slug" => "founder",
        "name" => "New Name",
        "headline" => "Updated",
        "persona_type" => "qualitative",
        "account_id" => account_id,
        "inserted_at" => DateTime.to_iso8601(persona.inserted_at),
        "updated_at" => "2026-04-24T13:00:00Z"
      }

      plug = stub_response(200, %{"data" => server_persona})

      assert {:ok, updated} =
               RemoteClient.update_persona(
                 scope,
                 persona,
                 %{name: "New Name", headline: "Updated", persona_type: "qualitative"},
                 plug: plug,
                 token: "test"
               )

      assert updated.name == "New Name"

      local = Repo.get(Persona, persona.id)
      assert local.name == "New Name"
      assert local.headline == "Updated"
      assert local.persona_type == :qualitative
    end
  end

  # ---------------------------------------------------------------------------
  # link_persona_to_story — upserts join row
  # ---------------------------------------------------------------------------

  describe "link_persona_to_story/4" do
    test "upserts the returned link into local persona_stories",
         %{scope: scope, account_id: account_id} do
      persona = insert_local_persona(account_id, slug: "founder")
      story = insert_local_story(account_id)

      server_link = %{
        "id" => "22222222-2222-2222-2222-222222222222",
        "persona_id" => persona.id,
        "story_id" => story.id,
        "inserted_at" => "2026-04-24T14:00:00Z",
        "updated_at" => "2026-04-24T14:00:00Z"
      }

      plug = stub_response(201, %{"data" => server_link})

      assert {:ok, link} =
               RemoteClient.link_persona_to_story(scope, persona.id, story.id,
                 plug: plug,
                 token: "test"
               )

      assert link.persona_id == persona.id
      assert link.story_id == story.id

      local = Repo.get_by(PersonaStory, persona_id: persona.id, story_id: story.id)
      assert local, "expected persona_stories row after successful remote link"
    end

    test "does NOT insert locally on cross_account error",
         %{scope: scope, account_id: account_id} do
      persona = insert_local_persona(account_id, slug: "founder")

      plug = stub_response(422, %{"error" => "cross_account"})

      before_count = Repo.aggregate(PersonaStory, :count)

      assert {:error, :cross_account} =
               RemoteClient.link_persona_to_story(scope, persona.id, 99_999,
                 plug: plug,
                 token: "test"
               )

      assert Repo.aggregate(PersonaStory, :count) == before_count
    end
  end

  # ---------------------------------------------------------------------------
  # unlink_persona_from_story — deletes local link
  # ---------------------------------------------------------------------------

  describe "unlink_persona_from_story/4" do
    test "deletes the matching local persona_stories row on 200",
         %{scope: scope, account_id: account_id} do
      persona = insert_local_persona(account_id, slug: "founder")
      story = insert_local_story(account_id)
      {:ok, _link} = insert_local_link(persona.id, story.id)

      plug = stub_response(200, %{"status" => "unlinked"})

      assert {:ok, :unlinked} =
               RemoteClient.unlink_persona_from_story(scope, persona.id, story.id,
                 plug: plug,
                 token: "test"
               )

      refute Repo.get_by(PersonaStory, persona_id: persona.id, story_id: story.id)
    end

    test "does NOT delete local row on 404",
         %{scope: scope, account_id: account_id} do
      persona = insert_local_persona(account_id, slug: "founder")
      story = insert_local_story(account_id)
      {:ok, _link} = insert_local_link(persona.id, story.id)

      plug = stub_response(404, %{"error" => "not_found"})

      assert {:error, :not_found} =
               RemoteClient.unlink_persona_from_story(scope, persona.id, story.id,
                 plug: plug,
                 token: "test"
               )

      assert Repo.get_by(PersonaStory, persona_id: persona.id, story_id: story.id),
             "expected local link to remain when server returned 404"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp stub_response(status, body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp insert_local_persona(account_id, attrs) do
    attrs =
      Enum.into(attrs, %{
        id: Ecto.UUID.generate(),
        slug: "test-persona",
        name: "Test",
        account_id: account_id,
        persona_type: :proto
      })

    %Persona{id: attrs.id}
    |> Persona.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_local_story(_account_id) do
    # Use the shared story_fixture so the required versions rows (`first_version_id`
    # and `current_version_id`) get populated.
    scope = full_scope_fixture()
    story_fixture(scope, %{title: "Link target story"})
  end

  defp insert_local_link(persona_id, story_id) do
    %PersonaStory{}
    |> PersonaStory.changeset(%{persona_id: persona_id, story_id: story_id})
    |> Repo.insert()
  end
end
