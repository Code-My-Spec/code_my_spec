defmodule CodeMySpec.Agents.Main.AQuestionGoesToTheAnswererItNamesTest do
  @moduledoc """
  Story 1052, three amigos 2026-10-11: coding and QA ask the product or main
  agent; whoever receives a question answers it, hands it to the other, or
  escalates it straight to the user.

  Criteria 2122 (an unaddressed question goes to main), 2124 (an answerer that
  is not running hands over to the other, then the user) and 1987 (product's
  own question goes straight to the user).
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Notifications
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Repo
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        device: CodeMySpec.DevicesFixtures.device_fixture(scope)
      )

    %{scope: %{scope | active_working_copy_id: copy.id}}
  end

  defp agent(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        status: :running,
        working_copy_id: scope.active_working_copy_id,
        working_copy: "/tmp/q-#{System.unique_integer([:positive])}"
      })

    AgentPresence.present(agent)
    agent
  end

  test "an unaddressed question goes to main", %{scope: scope} do
    agent(scope, :main)
    agent(scope, :product)
    coding = agent(scope, :coding)

    assert MainAgent.holder_for(scope, coding.id) == "main_agent"
  end

  test "a question addressed to product goes to product", %{scope: scope} do
    agent(scope, :main)
    agent(scope, :product)
    qa = agent(scope, :qa)

    assert MainAgent.holder_for(scope, qa.id, nil, "product") == "product_agent"
  end

  test "an answerer that is not running hands over to the other", %{scope: scope} do
    agent(scope, :product)
    coding = agent(scope, :coding)

    assert MainAgent.holder_for(scope, coding.id, nil, "main") == "product_agent"
  end

  test "with neither answerer running it is the user's", %{scope: scope} do
    coding = agent(scope, :coding)

    assert MainAgent.holder_for(scope, coding.id, nil, "product") == "user"
  end

  test "product's own question goes straight to the user", %{scope: scope} do
    agent(scope, :main)
    product = agent(scope, :product)

    assert MainAgent.holder_for(scope, product.id, nil, "main") == "user"
  end

  # Criterion 2123: a misrouted question moves sideways without reaching the user.
  test "main hands a question to product, and the user does not see it", %{scope: scope} do
    agent(scope, :main)
    agent(scope, :product)
    coding = agent(scope, :coding)
    request = question(scope, coding)

    assert {:ok, _} =
             MainAgent.hand_question(scope, request.id, "product", "it is about criteria")

    assert %{holder: "product_agent"} = Repo.get!(QuestionRequest, request.id)

    assert {:ok, _} = MainAgent.hand_question(scope, request.id, "main", "it is operational")
    assert %{holder: "main_agent"} = Repo.get!(QuestionRequest, request.id)
  end

  defp question(scope, asker) do
    {:ok, request} =
      Notifications.create_agent_question_request(
        scope,
        asker.id,
        %{
          "title" => "which copy?",
          "questions" => [%{"question" => "which copy?", "options" => []}],
          "holder" => MainAgent.holder_for(scope, asker.id)
        },
        nil
      )

    request
  end
end
