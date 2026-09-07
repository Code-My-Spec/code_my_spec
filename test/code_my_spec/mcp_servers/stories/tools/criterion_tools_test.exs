defmodule CodeMySpec.McpServers.Stories.Tools.CriterionToolsTest do
  use ExUnit.Case, async: true
  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.McpServers.Stories.Tools.{AddCriterion, DeleteCriterion, UpdateCriterion}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "AddCriterion" do
    test "adds criterion to story" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{title: "Test Story"})
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{story_id: to_string(story.id), description: "New acceptance criterion"}

      assert {:reply, response, ^frame} = AddCriterion.execute(params, frame)
      assert response.type == :tool
      refute response.isError

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]

      assert content =~ "Criterion added"
      assert content =~ "New acceptance criterion"
      assert content =~ "Test Story"
    end

    test "returns error for non-existent story" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{story_id: "99999", description: "Won't work"}

      assert {:reply, response, ^frame} = AddCriterion.execute(params, frame)
      assert response.isError == true
    end
  end

  describe "UpdateCriterion" do
    test "updates criterion description" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{title: "Test Story"})

      {:ok, criterion} =
        AcceptanceCriteria.create_criterion(scope, story, %{description: "Original"})

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{criterion_id: to_string(criterion.id), description: "Updated description"}

      assert {:reply, response, ^frame} = UpdateCriterion.execute(params, frame)
      assert response.type == :tool
      refute response.isError

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]

      assert content =~ "Criterion updated"
      assert content =~ "Updated description"
    end

    test "prevents updating verified criterion" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{title: "Test Story"})

      {:ok, criterion} =
        AcceptanceCriteria.create_criterion(scope, story, %{description: "Original"})

      {:ok, _verified} = AcceptanceCriteria.mark_verified(scope, criterion)

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{criterion_id: to_string(criterion.id), description: "Trying to change"}

      assert {:reply, response, ^frame} = UpdateCriterion.execute(params, frame)
      assert response.isError == true

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]

      assert content =~ "Cannot update verified"
    end

    test "returns error for non-existent criterion" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{criterion_id: "99999", description: "Won't work"}

      assert {:reply, response, ^frame} = UpdateCriterion.execute(params, frame)
      assert response.isError == true

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]

      assert content =~ "not found"
    end
  end

  describe "DeleteCriterion" do
    test "deletes criterion" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{title: "Test Story"})

      {:ok, criterion} =
        AcceptanceCriteria.create_criterion(scope, story, %{description: "To delete"})

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{criterion_id: to_string(criterion.id)}

      assert {:reply, response, ^frame} = DeleteCriterion.execute(params, frame)
      assert response.type == :tool
      refute response.isError

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]

      assert content =~ "Criterion deleted"
      assert content =~ "To delete"

      # Verify it's actually deleted
      assert AcceptanceCriteria.get_criterion(scope, criterion.id) == nil
    end

    test "prevents deleting verified criterion" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{title: "Test Story"})

      {:ok, criterion} =
        AcceptanceCriteria.create_criterion(scope, story, %{description: "Verified one"})

      {:ok, _verified} = AcceptanceCriteria.mark_verified(scope, criterion)

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{criterion_id: to_string(criterion.id)}

      assert {:reply, response, ^frame} = DeleteCriterion.execute(params, frame)
      assert response.isError == true

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]

      assert content =~ "Cannot delete verified"
    end

    test "returns error for non-existent criterion" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{criterion_id: "99999"}

      assert {:reply, response, ^frame} = DeleteCriterion.execute(params, frame)
      assert response.isError == true
    end
  end
end
