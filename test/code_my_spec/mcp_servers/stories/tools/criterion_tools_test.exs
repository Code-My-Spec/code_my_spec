defmodule CodeMySpec.McpServers.Stories.Tools.CriterionToolsTest do
  use ExUnit.Case, async: true
  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Stories.Tools.{AddCriterion, RetireCriterion}
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "AddCriterion" do
    test "adds criterion to story" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{title: "Test Story"})
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{story_number: story.number, description: "New acceptance criterion"}

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

      params = %{story_number: 99_999, description: "Won't work"}

      assert {:reply, response, ^frame} = AddCriterion.execute(params, frame)
      assert response.isError == true
    end
  end

  describe "RetireCriterion" do
    test "retires criterion" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{title: "Test Story"})

      {:ok, criterion} =
        AcceptanceCriteria.create_criterion(scope, story, %{description: "To retire"})

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{criterion_number: criterion.number}

      assert {:reply, response, ^frame} = RetireCriterion.execute(params, frame)
      assert response.type == :tool
      refute response.isError

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]

      assert content =~ "Criterion retired"
      assert content =~ "To retire"

      assert AcceptanceCriteria.get_criterion(scope, criterion.id).retired_at
    end

    test "prevents retiring verified criterion" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{title: "Test Story"})

      {:ok, criterion} =
        AcceptanceCriteria.create_criterion(scope, story, %{description: "Verified one"})

      {:ok, _verified} = AcceptanceCriteria.mark_verified(scope, criterion)

      frame = %Frame{assigns: %{current_scope: scope}}
      params = %{criterion_number: criterion.number}

      assert {:reply, response, ^frame} = RetireCriterion.execute(params, frame)
      assert response.isError == true

      protocol = Response.to_protocol(response)
      content = hd(protocol["content"])["text"]

      assert content =~ "Cannot retire a verified"
    end

    test "returns error for non-existent criterion" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      params = %{criterion_number: 99_999}

      assert {:reply, response, ^frame} = RetireCriterion.execute(params, frame)
      assert response.isError == true
    end
  end
end
