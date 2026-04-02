defmodule CodeMySpec.Architecture.ProposalProjectorTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Architecture.ProposalProjector
  alias CodeMySpec.Components.Dependency

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures

  setup do
    scope = full_scope_fixture()
    {:ok, scope: scope}
  end

  describe "project/1" do
    test "returns proposal markdown with empty architecture", %{scope: scope} do
      result = ProposalProjector.project(scope)

      assert result =~ "# Architecture Proposal"
      assert result =~ "## Contexts"
      assert result =~ "## Surface Components"
      assert result =~ "## Dependencies"
    end

    test "includes contexts with children", %{scope: scope} do
      context =
        component_fixture(scope, %{
          type: "context",
          name: "Accounts",
          module_name: "MyApp.Accounts",
          description: "User account management"
        })

      _schema =
        component_fixture(scope, %{
          type: "schema",
          name: "User",
          module_name: "MyApp.Accounts.User",
          description: "User record",
          parent_component_id: context.id
        })

      result = ProposalProjector.project(scope)

      assert result =~ "### MyApp.Accounts"
      assert result =~ "User account management"
      assert result =~ "#### Children"
      assert result =~ "MyApp.Accounts.User (schema): User record"
    end

    test "includes surface components with story mappings", %{scope: scope} do
      liveview =
        component_fixture(scope, %{
          type: "liveview",
          name: "DashboardLive",
          module_name: "MyAppWeb.DashboardLive",
          description: "Main dashboard"
        })

      _story = story_fixture(scope, %{component_id: liveview.id, title: "View dashboard"})

      result = ProposalProjector.project(scope)

      assert result =~ "### MyAppWeb.DashboardLive"
      assert result =~ "Main dashboard"
      assert result =~ "**Stories:**"
    end

    test "includes dependencies between components", %{scope: scope} do
      context =
        component_fixture(scope, %{
          type: "context",
          name: "Accounts",
          module_name: "MyApp.Accounts"
        })

      liveview =
        component_fixture(scope, %{
          type: "liveview",
          name: "AccountLive",
          module_name: "MyAppWeb.AccountLive"
        })

      %Dependency{}
      |> Dependency.changeset(%{
        source_component_id: liveview.id,
        target_component_id: context.id
      })
      |> CodeMySpec.Repo.insert!()

      result = ProposalProjector.project(scope)

      assert result =~ "MyAppWeb.AccountLive -> MyApp.Accounts"
    end

    test "separates contexts from surface components correctly", %{scope: scope} do
      _context =
        component_fixture(scope, %{
          type: "context",
          name: "Orders",
          module_name: "MyApp.Orders"
        })

      _liveview =
        component_fixture(scope, %{
          type: "liveview",
          name: "OrderLive",
          module_name: "MyAppWeb.OrderLive"
        })

      result = ProposalProjector.project(scope)

      # Context should be under Contexts section
      contexts_section = result |> String.split("## Surface Components") |> hd()
      assert contexts_section =~ "### MyApp.Orders"

      # Surface should be under Surface Components section
      surface_section = result |> String.split("## Surface Components") |> List.last()
      assert surface_section =~ "### MyAppWeb.OrderLive"
    end

    test "formats live_context with children and story ids", %{scope: scope} do
      live_context =
        component_fixture(scope, %{
          type: "live_context",
          name: "UserLive",
          module_name: "MyAppWeb.UserLive",
          description: "User management views"
        })

      _child_lv =
        component_fixture(scope, %{
          type: "liveview",
          name: "Index",
          module_name: "MyAppWeb.UserLive.Index",
          description: "List users",
          parent_component_id: live_context.id
        })

      result = ProposalProjector.project(scope)

      assert result =~ "### MyAppWeb.UserLive"
      assert result =~ "live_context"
      assert result =~ "#### Children"
      assert result =~ "MyAppWeb.UserLive.Index (liveview)"
    end
  end

  describe "change_summary/1" do
    test "reports unsatisfied stories", %{scope: scope} do
      _story = story_fixture(scope, %{title: "Unmapped story"})

      summary = ProposalProjector.change_summary(scope)

      assert summary =~ "stories without surface components"
      assert summary =~ "Unmapped story"
    end

    test "reports all stories mapped when none are unsatisfied", %{scope: scope} do
      liveview =
        component_fixture(scope, %{
          type: "liveview",
          name: "DashboardLive",
          module_name: "MyAppWeb.DashboardLive"
        })

      _story = story_fixture(scope, %{component_id: liveview.id, title: "Mapped story"})

      summary = ProposalProjector.change_summary(scope)

      assert summary =~ "All stories are mapped"
    end
  end
end
