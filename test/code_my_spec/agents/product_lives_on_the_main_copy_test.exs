defmodule CodeMySpec.Agents.ProductLivesOnTheMainCopyTest do
  @moduledoc """
  a31f1cd6 step 4c. John: "main and product on the main copy; coding and QA on
  each feature copy." Product designs an epic on the main copy, owns triage,
  three amigos and story design, and carries no staffing tools. Its own open
  question blocks only the task it was asked about (story 1080).
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main.AgentWork
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Agents.Waiting
  alias CodeMySpec.Agents.Wake
  alias CodeMySpec.EpicDispatch
  alias CodeMySpec.Epics
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias CodeMySpecTest.AgentPresence

  @product_work ~w(issues_triaged story_issues_triaged three_amigos_complete personas_complete
                   component_linked questions_answered)

  describe "the profile" do
    test "product's home is the main copy; a feature copy is coding and QA" do
      assert RoleProfile.get(:product).home_copy == :main
      assert RoleProfile.roles_where_home(:main) == [:main, :product]
      assert RoleProfile.feature_roles() == [:coding, :qa]
      assert Agents.copy_roles() == [:coding, :qa]
    end

    test "product drops the staffing and loop tools; main keeps every tool" do
      for tool <- ~w(create_working_copy offboard_working_copy set_working_copy_loop) do
        refute RoleProfile.carries?(:product, tool), "product still carries #{tool}"
        assert RoleProfile.carries?(:main, tool)
      end
    end

    test "triage, three amigos, personas and story design are product's alone" do
      for name <- @product_work do
        assert name in RequirementDefinitionData.requirement_names_for_role(:product)

        for role <- [:main, :coding, :qa] do
          refute name in RequirementDefinitionData.requirement_names_for_role(role),
                 "#{name} is offered to #{role}"
        end
      end

      assert "architecture_designed" in RequirementDefinitionData.requirement_names_for_role(
               :main
             )

      refute "architecture_designed" in RequirementDefinitionData.requirement_names_for_role(
               :product
             )
    end

    test "product's own open question holds none of it; main's only its nudge" do
      for path <- [:turn_end, :offer, :resume],
          do: refute(RoleProfile.waits_on?(:product, :question_pending, path))

      assert RoleProfile.waits_on?(:main, :question_pending, :turn_end)
      refute RoleProfile.waits_on?(:main, :question_pending, :offer)
    end
  end

  describe "the main copy" do
    setup :copies

    test "holds main and product, one each", %{scope: scope, main: main} do
      assert {:ok, _} = start(scope, "main", main)
      assert {:ok, product} = start(scope, "product", main)
      assert product.working_copy_id == main.id

      assert {:error, {:main_copy_occupied, :product, root}} = start(scope, "product", main)
      assert root == main.root
      assert {:error, {:main_copy_occupied, :main, _}} = start(scope, "main", main)
    end

    test "still refuses coding and QA", %{scope: scope, main: main} do
      for role <- ~w(coding qa) do
        assert {:error, {:not_at_home, _, _}} = start(scope, role, main)
      end
    end

    test "is staffed with main and product by default", %{scope: scope, main: main} do
      assert %{started: started, failed: []} = Agents.ensure_copy_agents(scope, main)
      assert started |> Enum.map(& &1.role) |> Enum.sort() == [:main, :product]
    end

    test "a feature copy is staffed with coding and QA only", %{scope: scope, feature: feature} do
      assert %{started: started, failed: []} = Agents.ensure_copy_agents(scope, feature)
      assert started |> Enum.map(& &1.role) |> Enum.sort() == [:coding, :qa]
    end

    test "bringing up the main agent brings up product, once", %{scope: scope, main: main} do
      assert {:ok, %Agent{role: :main}} = Agents.ensure_main_agent(scope)
      assert {:ok, _} = Agents.ensure_main_agent(scope)

      assert [%Agent{working_copy_id: id}] = live(scope, :product)
      assert id == main.id
    end

    test "product moves with main when the main copy moves", ctx do
      {:ok, _} = start(ctx.scope, "main", ctx.main)
      {:ok, _} = start(ctx.scope, "product", ctx.main)

      {:ok, _} = Agents.move_main_agent(ctx.scope, ctx.feature)

      assert [%Agent{working_copy_id: id}] = live(ctx.scope, :product)
      assert id == ctx.feature.id
    end
  end

  describe "product's own open question" do
    setup do
      scope = full_scope_fixture()
      product = running(scope, :product)
      main = running(scope, :main)
      %{scope: scope, product: product, main: main}
    end

    test "holds none of its nudge, work offers or resume", %{scope: scope, product: product} do
      ask(scope, product, "main_agent")

      for path <- [:turn_end, :offer, :resume] do
        assert Waiting.reason(scope, product, path) == nil, inspect(path)
      end

      assert :ok = Wake.allow?(scope, product, :work_offer)
      assert :ok = Wake.allow?(scope, product, :nudge)
    end

    test "still lets its answer and a teammate's question through", ctx do
      ask(ctx.scope, ctx.product, "main_agent")

      assert :ok = Wake.allow?(ctx.scope, ctx.product, :question_answered)
      assert :ok = Wake.allow?(ctx.scope, ctx.product, :teammate_question)
    end

    test "main's own question still holds only its nudge", %{scope: scope, main: main} do
      ask(scope, main, "user")

      assert {:hold, :question_pending} = Wake.allow?(scope, main, :nudge)
      assert :ok = Wake.allow?(scope, main, :work_offer)
    end

    test "a product idle beside work while its question is open is reported stalled", ctx do
      entry = %AgentWork{
        agent_id: ctx.product.id,
        role: :product,
        agent_status: :running,
        continuous?: true,
        blocked_reasons: ["Which way?"]
      }

      assert Digest.stalled(%Digest{work: [entry]}) == [entry]
      assert AgentWork.unclaimed_work(entry) =~ "STALLED"
    end
  end

  describe "product's epic" do
    setup :copies

    setup %{scope: scope} do
      {:ok, epic} = Epics.create_epic(scope, %{name: "Designed on main"})
      story = story_fixture(scope)
      story = story |> Ecto.Changeset.change(epic_id: epic.id) |> Repo.update!()
      %{epic: epic, story: story}
    end

    test "is the epic it is designing, and dispatch takes it away", ctx do
      {:ok, product} = start(ctx.scope, "product", ctx.main)
      {:ok, coding} = start(ctx.scope, "coding", ctx.feature)

      assert :ok = Agents.claim_story(ctx.scope, product, ctx.story.id)
      assert Repo.get!(Agent, product.id).epic_id == ctx.epic.id
      assert Repo.get!(Agent, product.id).story_id == nil

      {:ok, _} = EpicDispatch.place(ctx.scope, ctx.epic.id, ctx.feature.id)

      assert Repo.get!(Agent, product.id).epic_id == nil,
             "product is not sent with the epic; it stays on the main copy"

      assert Repo.get!(Agent, coding.id).epic_id == ctx.epic.id
    end
  end

  defp copies(_ctx) do
    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})
    {:ok, main} = WorkingCopies.fetch(scope.active_working_copy_id)
    device = device_fixture(scope)
    n = System.unique_integer([:positive])

    main =
      main
      |> Ecto.Changeset.change(root: "/workspace/main-#{n}", main: true, device_id: device.id)
      |> Repo.update!()

    feature =
      %WorkingCopy{}
      |> WorkingCopy.changeset(%{
        project_id: scope.active_project_id,
        device_id: device.id,
        root: "/workspace/feature-#{n}",
        label: "a feature checkout"
      })
      |> Repo.insert!()

    %{scope: %{scope | cwd: main.root}, main: main, feature: feature}
  end

  defp start(scope, role, copy) do
    Agents.start_agent(scope, %{
      provider: "anthropic",
      role: role,
      engine: :alloy,
      working_copy_id: copy.id
    })
  end

  defp live(scope, role) do
    scope
    |> Agents.list_agents()
    |> Enum.filter(&(&1.role == role and &1.status != :stopped and not Agent.retired?(&1)))
  end

  defp running(scope, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        status: :running,
        continuous: true,
        working_copy: "/tmp/rp4c-#{role}",
        working_copy_id: scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    agent
  end

  defp ask(scope, agent, holder) do
    %QuestionRequest{}
    |> QuestionRequest.changeset(%{
      user_id: scope.user.id,
      agent_id: agent.id,
      title: "Which approach?",
      questions: [%{"question" => "Which?", "options" => [%{"label" => "A"}]}],
      holder: holder
    })
    |> Repo.insert!()
  end
end
