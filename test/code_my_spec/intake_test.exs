defmodule CodeMySpec.IntakeTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Accounts
  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.Plan
  alias CodeMySpec.Personas
  alias CodeMySpec.Projects
  alias CodeMySpec.Repo

  defp planned_plan(description \\ "a booking tool for hair salons") do
    token = Intake.new_session_token()
    {:ok, plan} = Intake.start_plan(token)
    {:ok, plan} = Intake.describe(plan, description)

    {:ok, plan} =
      Intake.answer(plan, %{needs_sign_in: true, separate_copies: true, who_uses: "salon owners"})

    {:ok, plan} = Intake.generate_plan(plan)
    plan
  end

  describe "anonymous plans" do
    test "a visitor reaches a plan without a user existing" do
      plan = planned_plan()

      assert plan.status == :planned
      assert plan.summary =~ "salon owners"
      assert plan.first_build
      assert plan.account_name
      assert plan.project_name
    end

    test "the plan states what it concluded about sign-in and separate copies" do
      plan = planned_plan()

      assert plan.summary =~ "People sign in to use it."
      assert plan.summary =~ "Each business gets its own separate copy"
    end

    test "an unanswered shaping question is not a false" do
      {:ok, plan} = Intake.start_plan(Intake.new_session_token())
      {:ok, plan} = Intake.describe(plan, "a thing")

      assert {:error, changeset} = Intake.answer(plan, %{who_uses: "someone"})
      assert %{needs_sign_in: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "the transcript once a plan is generated (7df5485e)" do
    test "the agent's side of landing on a plan is a turn, not silence" do
      plan = planned_plan()

      said = plan |> Intake.transcript() |> Enum.map_join("\n", & &1.text)

      assert said =~ "Here's what I think you're building", """
      `shaped/2` can decide no follow-up question is needed and go straight
      from a description to a generated plan, leaving `pending_question` nil
      the whole time. `shaping/2` only ever spoke by way of that field, so this
      path landed on `:planned` with nothing in the transcript to say the
      agent answered at all — the visitor's own message just sat there while
      the plan card filled in on its own.

      Transcript was:
      #{said}
      """
    end
  end

  describe "coming back" do
    test "the same token finds the plan waiting" do
      plan = planned_plan()

      found = Intake.get_plan(plan.session_token)

      assert found.id == plan.id
      assert found.account_name == plan.account_name
    end

    test "a token from another browser finds nothing rather than an error" do
      planned_plan()

      assert Intake.get_plan(Intake.new_session_token()) == nil
    end

    test "starting twice on the same token adopts the existing plan" do
      plan = planned_plan()

      assert {:ok, again} = Intake.start_plan(plan.session_token)
      assert again.id == plan.id
      assert again.status == :planned
    end
  end

  describe "confirming names" do
    test "a correction overwrites the proposal in place" do
      plan = planned_plan()

      {:ok, corrected} =
        Intake.confirm_names(plan, %{account_name: "Acme", project_name: "Widget Tracker"})

      assert corrected.account_name == "Acme"
      assert corrected.project_name == "Widget Tracker"
    end
  end

  describe "convert/2" do
    # `who_uses` was collected from the first conversation and used only to
    # write a summary. The project was created without a persona, and that is
    # not cosmetic: `personas_complete` is a project requirement and `add_rule`
    # refuses a story with no persona linked, so the first Three Amigos on a
    # project born from intake stopped until somebody invented one — throwing
    # away the answer the visitor had actually given.
    test "the project gets a persona for who the visitor said it is for" do
      scope = user_scope_fixture()
      plan = planned_plan()

      {:ok, plan} =
        Intake.confirm_names(plan, %{account_name: "Acme", project_name: "Widget Tracker"})

      assert {:ok, converted} = Intake.convert(plan, scope)

      project_scope = %{scope | active_project_id: converted.project_id}

      assert [persona] = Personas.list_personas(project_scope),
             "the project was created with nobody it is for, so its first Three " <>
               "Amigos is blocked on inventing a persona the visitor already described"

      assert persona.name == "salon owners"
      assert persona.persona_type == :proto
    end

    test "a plan that never said who it is for still converts" do
      scope = user_scope_fixture()
      token = Intake.new_session_token()
      {:ok, plan} = Intake.start_plan(token)
      {:ok, plan} = Intake.describe(plan, "something for me")
      {:ok, plan} = Intake.answer(plan, %{needs_sign_in: false, separate_copies: false})
      {:ok, plan} = Intake.generate_plan(plan)

      {:ok, plan} =
        Intake.confirm_names(plan, %{account_name: "Acme", project_name: "Widget Tracker"})

      assert {:ok, _converted} = Intake.convert(plan, scope),
             "a missing persona must not cost the visitor their project — no persona " <>
               "is worse than one, and no project is worse than both"
    end

    test "creates the account and project under the confirmed names" do
      scope = user_scope_fixture()
      plan = planned_plan()

      {:ok, plan} =
        Intake.confirm_names(plan, %{account_name: "Acme", project_name: "Widget Tracker"})

      assert {:ok, converted} = Intake.convert(plan, scope)
      assert converted.status == :converted

      account = Accounts.get_account_by_id(converted.account_id)
      project = Repo.get!(Projects.Project, converted.project_id)

      assert account.name == "Acme"
      assert project.name == "Widget Tracker"
      assert project.account_id == account.id
    end

    test "a name someone else already uses is accepted anyway" do
      account_fixture(%{name: "Acme", slug: "acme"})

      scope = user_scope_fixture()
      plan = planned_plan()
      {:ok, plan} = Intake.confirm_names(plan, %{account_name: "Acme", project_name: "Thing"})

      assert {:ok, converted} = Intake.convert(plan, scope)

      account = Accounts.get_account_by_id(converted.account_id)
      assert account.name == "Acme"
      assert account.slug == "acme-2"
    end

    test "signing in with an existing account adds a project rather than a second account" do
      user = user_fixture()
      account = account_fixture()
      member_fixture(user, account)
      scope = user_scope_fixture(user, account)

      existing = Repo.aggregate(Accounts.Account, :count)

      plan = planned_plan()
      {:ok, plan} = Intake.confirm_names(plan, %{account_name: "Ignored", project_name: "Thing"})

      assert {:ok, converted} = Intake.convert(plan, scope)

      assert converted.account_id == account.id
      assert Repo.aggregate(Accounts.Account, :count) == existing
    end

    test "converting an already-converted plan returns what it created" do
      scope = user_scope_fixture()
      plan = planned_plan()
      {:ok, plan} = Intake.confirm_names(plan, %{account_name: "Acme", project_name: "Thing"})

      {:ok, converted} = Intake.convert(plan, scope)
      assert {:ok, again} = Intake.convert(converted, scope)

      assert again.account_id == converted.account_id
      assert again.project_id == converted.project_id

      # About this plan, not about the table. "The whole table holds one row"
      # only held because the sandbox starts empty, and broke the moment
      # anything wrote a plan outside it.
      assert again.id == converted.id
      assert Repo.aggregate(from(p in Plan, where: p.id == ^converted.id), :count) == 1
    end
  end
end
