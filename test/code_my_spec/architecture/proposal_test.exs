defmodule CodeMySpec.Architecture.ProposalTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Architecture.Proposal

  setup do
    scope = full_scope_fixture()
    {:ok, scope: scope}
  end

  describe "new/1" do
    test "creates proposal from map with atom keys" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Fuellytics.Verification",
              description: "Verification context",
              children: [],
              story_ids: [1, 2]
            }
          ],
          surface_components: [
            %{name: "FuellyticsWeb.DashboardLive", type: "liveview", description: "Dashboard"}
          ],
          dependencies: [
            %{from: "FuellyticsWeb.DashboardLive", to: "Fuellytics.Verification"}
          ]
        })

      assert proposal.app_name == "Fuellytics"
      assert length(proposal.contexts) == 1
      assert length(proposal.surface_components) == 1
      assert length(proposal.dependencies) == 1
    end

    test "creates proposal from map with string keys" do
      proposal =
        Proposal.new(%{
          "app_name" => "Fuellytics",
          "contexts" => [
            %{"name" => "Fuellytics.Verification", "description" => "Verification context"}
          ]
        })

      assert proposal.app_name == "Fuellytics"
      assert length(proposal.contexts) == 1
    end

    test "defaults app_name to 'App' when not provided" do
      proposal = Proposal.new(%{})

      assert proposal.app_name == "App"
    end
  end

  describe "validate/2" do
    test "returns ok for valid proposal with dual story mapping" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Fuellytics.Verification",
              description: "Test",
              children: [
                %{name: "Fuellytics.Verification.Transaction", type: "schema", story_ids: [1]}
              ]
            }
          ],
          surface_components: [
            %{name: "FuellyticsWeb.DashboardLive", type: "liveview", story_ids: [1]}
          ]
        })

      # When no story_ids provided, validation skips story coverage checks
      assert {:ok, ^proposal} = Proposal.validate(proposal)
    end

    test "returns error for invalid module names" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "invalid_name",
              description: "Test",
              children: [%{name: "invalid_name.X", type: "schema"}]
            }
          ]
        })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :invalid_naming))
    end

    test "returns error for duplicate names" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Fuellytics.Verification",
              description: "Test",
              children: [%{name: "Fuellytics.Verification.X", type: "schema"}]
            },
            %{
              name: "Fuellytics.Verification",
              description: "Duplicate",
              children: [%{name: "Fuellytics.Verification.Y", type: "schema"}]
            }
          ]
        })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :duplicate_names))
    end

    test "returns error for circular dependencies" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Fuellytics.A",
              description: "A",
              children: [%{name: "Fuellytics.A.X", type: "schema"}]
            },
            %{
              name: "Fuellytics.B",
              description: "B",
              children: [%{name: "Fuellytics.B.Y", type: "schema"}]
            }
          ],
          dependencies: [
            %{from: "Fuellytics.A", to: "Fuellytics.B"},
            %{from: "Fuellytics.B", to: "Fuellytics.A"}
          ]
        })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :dependency_cycle))
    end

    test "requires stories to be mapped to surface components" do
      # Story mapped to context but not surface
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Fuellytics.A",
              description: "A",
              children: [%{name: "Fuellytics.A.X", type: "schema", story_ids: [1, 2]}]
            }
          ],
          surface_components: [
            %{name: "FuellyticsWeb.DashboardLive", type: "liveview"}
          ]
        })

      assert {:error, errors} = Proposal.validate(proposal, story_ids: [1, 2])
      assert Enum.any?(errors, &(&1.type == :stories_missing_surface))
    end

    test "accepts stories mapped to both surface and context" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Fuellytics.A",
              description: "A",
              children: [%{name: "Fuellytics.A.X", type: "schema", story_ids: [1, 2]}]
            }
          ],
          surface_components: [
            %{name: "FuellyticsWeb.DashboardLive", type: "liveview", story_ids: [1, 2]}
          ]
        })

      assert {:ok, _} = Proposal.validate(proposal, story_ids: [1, 2])
    end

    test "accepts stories mapped to context itself (not just children)" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Fuellytics.A",
              description: "A",
              story_ids: [1],
              children: [%{name: "Fuellytics.A.X", type: "schema"}]
            }
          ],
          surface_components: [
            %{name: "FuellyticsWeb.DashboardLive", type: "liveview", story_ids: [1]}
          ]
        })

      assert {:ok, _} = Proposal.validate(proposal, story_ids: [1])
    end

    test "returns error for child not starting with parent context name" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Fuellytics.Verification",
              description: "Test",
              children: [%{name: "Transaction", type: "schema"}]
            }
          ],
          surface_components: [
            %{name: "FuellyticsWeb.DashboardLive", type: "liveview", story_ids: [1]}
          ]
        })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :invalid_naming_hierarchy))
    end

    test "returns error for context not starting with app name" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Verification",
              description: "Test",
              children: [%{name: "Verification.Transaction", type: "schema"}]
            }
          ],
          surface_components: [
            %{name: "FuellyticsWeb.DashboardLive", type: "liveview", story_ids: [1]}
          ]
        })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :invalid_naming_hierarchy))
    end

    test "returns error for surface component not starting with app web name" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Fuellytics.Verification",
              description: "Test",
              children: [%{name: "Fuellytics.Verification.Transaction", type: "schema"}]
            }
          ],
          surface_components: [
            %{name: "DashboardLive", type: "liveview", story_ids: [1]}
          ]
        })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :invalid_naming_hierarchy))
    end

    test "allows consecutive capitals in module names (Macro.underscore handles them)" do
      proposal =
        Proposal.new(%{
          app_name: "MetricFlow",
          contexts: [
            %{
              name: "MetricFlow.AI",
              description: "AI context",
              children: [
                %{name: "MetricFlow.AI.LLMClient", type: "module", description: "LLM client"}
              ]
            }
          ],
          surface_components: [
            %{name: "MetricFlowWeb.AILive", type: "liveview", story_ids: [1]}
          ]
        })

      assert {:ok, _} = Proposal.validate(proposal)
    end

    test "returns error for invalid component types" do
      # Types like "liveview (existing)" are invalid - must be exact match
      proposal =
        Proposal.new(%{
          app_name: "MetricFlow",
          contexts: [
            %{
              name: "MetricFlow.Users",
              description: "User management",
              children: []
            }
          ],
          surface_components: [
            %{
              name: "MetricFlowWeb.UserLive.Login",
              type: "liveview (existing)",
              story_ids: [1]
            }
          ]
        })

      assert {:error, errors} = Proposal.validate(proposal)
      error = Enum.find(errors, &(&1.type == :invalid_type))
      assert error != nil
      assert error.message =~ "must be one of"
      assert Enum.any?(error.details.invalid, &(&1 =~ "liveview (existing)"))
    end
  end

  describe "to_components/1" do
    test "returns all components from contexts and surface" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Fuellytics.Verification",
              description: "Verification context",
              children: [
                %{
                  name: "Fuellytics.Verification.Transaction",
                  type: "schema",
                  description: "Transaction schema"
                }
              ]
            }
          ],
          surface_components: [
            %{
              name: "FuellyticsWeb.DashboardLive",
              type: "liveview",
              description: "Dashboard",
              story_ids: [1, 2]
            }
          ]
        })

      components = Proposal.to_components(proposal)

      # context + child + surface
      assert length(components) == 3
    end

    test "context has type 'context'" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{name: "Fuellytics.Verification", description: "Verification context", children: []}
          ],
          surface_components: []
        })

      components = Proposal.to_components(proposal)
      context = Enum.find(components, &(&1.module_name == "Fuellytics.Verification"))

      assert context.type == "context"
    end

    test "child components include parent_module reference" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Fuellytics.Verification",
              description: "Verification context",
              children: [
                %{
                  name: "Fuellytics.Verification.Transaction",
                  type: "schema",
                  description: "Transaction schema"
                }
              ]
            }
          ],
          surface_components: []
        })

      components = Proposal.to_components(proposal)
      child = Enum.find(components, &(&1.module_name == "Fuellytics.Verification.Transaction"))

      assert child.parent_module == "Fuellytics.Verification"
    end

    test "surface components have correct type" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [],
          surface_components: [
            %{name: "FuellyticsWeb.DashboardLive", type: "liveview", description: "Dashboard"}
          ]
        })

      components = Proposal.to_components(proposal)
      surface = Enum.find(components, &(&1.module_name == "FuellyticsWeb.DashboardLive"))

      assert surface.type == "liveview"
    end
  end

  describe "execute/3" do
    setup do
      scope = full_scope_fixture()
      {:ok, tmp_dir} = Briefly.create(directory: true)
      {:ok, scope: scope, tmp_dir: tmp_dir}
    end

    test "returns preview without creating files (dry_run: true)" do
      proposal =
        Proposal.new(%{
          app_name: "Fuellytics",
          contexts: [
            %{
              name: "Fuellytics.Verification",
              description: "Verification",
              children: [
                %{
                  name: "Fuellytics.Verification.Transaction",
                  type: "schema",
                  description: "Transaction"
                }
              ]
            }
          ],
          surface_components: [
            %{name: "FuellyticsWeb.DashboardLive", type: "liveview", story_ids: [1]}
          ]
        })

      # We can test dry_run without a scope since it doesn't actually create anything
      assert {:ok, result} = Proposal.execute(proposal, nil, dry_run: true)

      assert result.created_contexts == 1
      # context + child + surface
      assert result.created_components == 3
      assert result.linked_stories == 1
      assert length(result.components) == 3
    end

    test "skips writing spec file if it already exists", %{tmp_dir: tmp_dir, scope: scope} do
      # Create a pre-existing spec file with custom content
      existing_spec_path = Path.join(tmp_dir, ".code_my_spec/spec/test_app/dashboards.spec.md")
      File.mkdir_p!(Path.dirname(existing_spec_path))
      existing_content = "# Existing Spec\n\nThis content should be preserved."
      File.write!(existing_spec_path, existing_content)

      proposal =
        Proposal.new(%{
          app_name: "TestApp",
          contexts: [
            %{
              name: "TestApp.Dashboards",
              description: "Dashboard management",
              children: []
            }
          ],
          surface_components: [
            %{name: "TestAppWeb.DashboardLive", type: "liveview", description: "Dashboard view"}
          ]
        })

      assert {:ok, _result} = Proposal.execute(proposal, scope, working_dir: tmp_dir)

      # Pre-existing spec should NOT be overwritten
      assert File.read!(existing_spec_path) == existing_content

      # New spec files should still be created
      surface_spec = Path.join(tmp_dir, ".code_my_spec/spec/test_app_web/dashboard_live.spec.md")
      assert File.exists?(surface_spec)
    end

    test "creates spec files at correct paths", %{tmp_dir: tmp_dir, scope: scope} do
      proposal =
        Proposal.new(%{
          app_name: "TestApp",
          contexts: [
            %{
              name: "TestApp.Dashboards",
              description: "Dashboard management",
              children: [
                %{
                  name: "TestApp.Dashboards.Dashboard",
                  type: "schema",
                  description: "Dashboard entity"
                }
              ]
            }
          ],
          surface_components: [
            %{name: "TestAppWeb.DashboardLive", type: "liveview", description: "Dashboard view"}
          ]
        })

      assert {:ok, _result} = Proposal.execute(proposal, scope, working_dir: tmp_dir)

      # Check spec files were created at expected paths
      context_spec = Path.join(tmp_dir, ".code_my_spec/spec/test_app/dashboards.spec.md")
      child_spec = Path.join(tmp_dir, ".code_my_spec/spec/test_app/dashboards/dashboard.spec.md")
      surface_spec = Path.join(tmp_dir, ".code_my_spec/spec/test_app_web/dashboard_live.spec.md")

      assert File.exists?(context_spec), "Expected #{context_spec} to exist"
      assert File.exists?(child_spec), "Expected #{child_spec} to exist"
      assert File.exists?(surface_spec), "Expected #{surface_spec} to exist"

      # Verify content includes module name and type
      context_content = File.read!(context_spec)
      assert context_content =~ "# TestApp.Dashboards"
      assert context_content =~ "## Type"
      assert context_content =~ "context"
    end

    test "syncs components to database", %{tmp_dir: tmp_dir, scope: scope} do
      alias CodeMySpec.Components

      proposal =
        Proposal.new(%{
          app_name: "MetricFlow",
          contexts: [
            %{
              name: "MetricFlow.Dashboards",
              description: "Dashboard management",
              children: []
            }
          ],
          surface_components: [
            %{
              name: "MetricFlowWeb.DashboardLive",
              type: "liveview",
              description: "Dashboard view"
            }
          ]
        })

      assert {:ok, result} = Proposal.execute(proposal, scope, working_dir: tmp_dir)
      assert result.created_components == 2

      # Verify components were synced to database
      components = Components.list_components(scope)
      module_names = Enum.map(components, & &1.module_name)

      assert "MetricFlow.Dashboards" in module_names
      assert "MetricFlowWeb.DashboardLive" in module_names
    end

    test "links stories to surface components only", %{tmp_dir: tmp_dir, scope: scope} do
      alias CodeMySpec.Stories
      alias CodeMySpec.Components

      # Create stories to link
      {:ok, story1} = Stories.create_story(scope, %{title: "Story 1", description: "First story"})

      {:ok, story2} =
        Stories.create_story(scope, %{title: "Story 2", description: "Second story"})

      proposal =
        Proposal.new(%{
          app_name: "MetricFlow",
          contexts: [
            %{
              name: "MetricFlow.Dashboards",
              description: "Dashboard management",
              story_ids: [story1.id, story2.id],
              children: [
                %{name: "MetricFlow.Dashboards.Dashboard", type: "schema", story_ids: [story1.id]}
              ]
            }
          ],
          surface_components: [
            %{
              name: "MetricFlowWeb.DashboardLive",
              type: "liveview",
              story_ids: [story1.id, story2.id]
            }
          ]
        })

      assert {:ok, result} = Proposal.execute(proposal, scope, working_dir: tmp_dir)

      # Stories should be linked to surface component only
      assert result.linked_stories == 2

      # Verify the liveview got the story links
      liveview = Components.get_component_by_module_name(scope, "MetricFlowWeb.DashboardLive")
      story1_updated = Stories.get_story(scope, story1.id)
      story2_updated = Stories.get_story(scope, story2.id)

      assert story1_updated.component_id == liveview.id
      assert story2_updated.component_id == liveview.id

      # Context/schema components should NOT have stories linked directly
      context = Components.get_component_by_module_name(scope, "MetricFlow.Dashboards")
      schema = Components.get_component_by_module_name(scope, "MetricFlow.Dashboards.Dashboard")

      # Get stories linked to context/schema (should be none)
      context_stories =
        Stories.list_stories(scope) |> Enum.filter(&(&1.component_id == context.id))

      schema_stories = Stories.list_stories(scope) |> Enum.filter(&(&1.component_id == schema.id))

      assert context_stories == []
      assert schema_stories == []
    end

    test "links stories to pre-existing surface components", %{tmp_dir: tmp_dir, scope: scope} do
      alias CodeMySpec.Stories
      alias CodeMySpec.Components

      # Create a component that already exists before proposal execution
      {:ok, existing_component} =
        Components.create_component(scope, %{
          module_name: "MetricFlowWeb.UserLive.Login",
          name: "Login",
          type: "liveview",
          description: "User login"
        })

      # Create stories to link
      {:ok, story} =
        Stories.create_story(scope, %{title: "Login Story", description: "User can login"})

      proposal =
        Proposal.new(%{
          app_name: "MetricFlow",
          contexts: [
            %{
              name: "MetricFlow.Users",
              description: "User management",
              children: []
            }
          ],
          surface_components: [
            %{
              name: "MetricFlowWeb.UserLive.Login",
              type: "liveview",
              description: "User login (existing)",
              story_ids: [story.id]
            }
          ]
        })

      assert {:ok, result} = Proposal.execute(proposal, scope, working_dir: tmp_dir)

      # Story should be linked
      assert result.linked_stories == 1

      # The existing component should be upserted (same id)
      component = Components.get_component_by_module_name(scope, "MetricFlowWeb.UserLive.Login")
      assert component.id == existing_component.id

      # Story should be linked to the existing component
      story_updated = Stories.get_story(scope, story.id)
      assert story_updated.component_id == existing_component.id
    end
  end

  describe "from_markdown/2" do
    test "parses surface component descriptions from markdown" do
      markdown = """
      # Architecture Proposal

      ## Surface Components

      ### MetricFlowWeb.DashboardLive.Index

      - **Type:** liveview
      - **Description:** Main dashboard for viewing metrics
      - **Stories:** 1, 2

      ## Contexts

      ### MetricFlow.Dashboards

      - **Type:** context
      - **Description:** Dashboard management context
      - **Stories:** 1, 2

      #### Children

      - MetricFlow.Dashboards.Dashboard (schema) [Stories: 1]: Dashboard entity

      ## Dependencies

      - MetricFlowWeb.DashboardLive.Index -> MetricFlow.Dashboards
      """

      assert {:ok, proposal} = Proposal.from_markdown(markdown, app_name: "MetricFlow")

      # Surface component should have description
      surface = hd(proposal.surface_components)
      assert surface.name == "MetricFlowWeb.DashboardLive.Index"
      assert surface.description == "Main dashboard for viewing metrics"

      # Context should have description
      context = hd(proposal.contexts)
      assert context.name == "MetricFlow.Dashboards"
      assert context.description == "Dashboard management context"
    end

    test "parses child component descriptions from markdown" do
      markdown = """
      # Architecture Proposal

      ## Surface Components

      ### MetricFlowWeb.DashboardLive

      - **Type:** liveview
      - **Description:** Dashboard view
      - **Stories:** 1

      ## Contexts

      ### MetricFlow.Dashboards

      - **Type:** context
      - **Description:** Dashboard management
      - **Stories:** 1

      #### Children

      - MetricFlow.Dashboards.Dashboard (schema) [Stories: 1]: The dashboard entity with title and layout
      - MetricFlow.Dashboards.Widget (schema) [Stories: 1] - Widget configuration record

      ## Dependencies

      - MetricFlowWeb.DashboardLive -> MetricFlow.Dashboards
      """

      assert {:ok, proposal} = Proposal.from_markdown(markdown, app_name: "MetricFlow")

      context = hd(proposal.contexts)
      assert length(context.children) == 2

      dashboard = Enum.find(context.children, &(&1.name == "MetricFlow.Dashboards.Dashboard"))
      assert dashboard.description == "The dashboard entity with title and layout"

      widget = Enum.find(context.children, &(&1.name == "MetricFlow.Dashboards.Widget"))
      assert widget.description == "Widget configuration record"
    end

    test "descriptions flow through to_components" do
      proposal =
        Proposal.new(%{
          app_name: "MetricFlow",
          contexts: [
            %{
              name: "MetricFlow.Dashboards",
              description: "Dashboard management context",
              children: [
                %{
                  name: "MetricFlow.Dashboards.Dashboard",
                  type: "schema",
                  description: "Dashboard entity"
                }
              ]
            }
          ],
          surface_components: [
            %{
              name: "MetricFlowWeb.DashboardLive",
              type: "liveview",
              description: "Dashboard view"
            }
          ]
        })

      components = Proposal.to_components(proposal)

      context = Enum.find(components, &(&1.module_name == "MetricFlow.Dashboards"))
      assert context.description == "Dashboard management context"

      child = Enum.find(components, &(&1.module_name == "MetricFlow.Dashboards.Dashboard"))
      assert child.description == "Dashboard entity"

      surface = Enum.find(components, &(&1.module_name == "MetricFlowWeb.DashboardLive"))
      assert surface.description == "Dashboard view"
    end

    test "parses dependencies from markdown" do
      markdown = """
      # Architecture Proposal

      ## Surface Components

      ### MetricFlowWeb.DashboardLive

      - **Type:** liveview
      - **Description:** Dashboard
      - **Stories:** 1

      ## Contexts

      ### MetricFlow.Dashboards

      - **Type:** context
      - **Description:** Dashboards
      - **Stories:** 1

      #### Children

      - MetricFlow.Dashboards.Dashboard (schema) [Stories: 1]: Entity

      ## Dependencies

      - MetricFlowWeb.DashboardLive -> MetricFlow.Dashboards
      - MetricFlowWeb.DashboardLive -> MetricFlow.Accounts
      """

      assert {:ok, proposal} = Proposal.from_markdown(markdown, app_name: "MetricFlow")

      assert length(proposal.dependencies) == 2

      assert %{from: "MetricFlowWeb.DashboardLive", to: "MetricFlow.Dashboards"} in proposal.dependencies

      assert %{from: "MetricFlowWeb.DashboardLive", to: "MetricFlow.Accounts"} in proposal.dependencies
    end

    test "parses alternate format with description as plain paragraph" do
      markdown = """
      # Architecture Proposal

      ## Contexts

      ### MetricFlow.Agencies
      Agency-specific features: team management, white-labeling, client account origination.

      **Type:** context

      **Children:**
      - MetricFlow.Agencies.AutoEnrollmentRule (schema) - Domain-based auto-enrollment config
      - MetricFlow.Agencies.WhiteLabelConfig (schema) - Branding: logo, colors, subdomain
      - MetricFlow.Agencies.AgenciesRepository (module) - Agency feature operations

      **Stories:** 427, 453, 454

      ## Surface Components

      ### MetricFlowWeb.AgencyLive
      Agency management interface for admins.

      **Type:** liveview

      **Stories:** 427

      ## Dependencies

      - MetricFlowWeb.AgencyLive -> MetricFlow.Agencies
      """

      assert {:ok, proposal} = Proposal.from_markdown(markdown, app_name: "MetricFlow")

      # Context should have description from paragraph
      context = hd(proposal.contexts)
      assert context.name == "MetricFlow.Agencies"

      assert context.description ==
               "Agency-specific features: team management, white-labeling, client account origination."

      assert context.story_ids == [427, 453, 454]

      # Children should have descriptions
      assert length(context.children) == 3
      rule = Enum.find(context.children, &(&1.name == "MetricFlow.Agencies.AutoEnrollmentRule"))
      assert rule.type == "schema"
      assert rule.description == "Domain-based auto-enrollment config"

      # Surface component should have description from paragraph
      surface = hd(proposal.surface_components)
      assert surface.name == "MetricFlowWeb.AgencyLive"
      assert surface.description == "Agency management interface for admins."
    end

    test "parses nested child module names" do
      markdown = """
      # Architecture Proposal

      ## Contexts

      ### MetricFlow.DataSync
      Sync scheduling and execution.

      **Type:** context

      **Children:**
      - MetricFlow.DataSync.SyncJob (schema) - Scheduled job
      - MetricFlow.DataSync.DataProviders.GoogleAds (module) - Pulls Google Ads metrics

      **Stories:** 1

      ## Surface Components

      ### MetricFlowWeb.SyncLive

      **Type:** liveview

      **Stories:** 1

      ## Dependencies

      - MetricFlowWeb.SyncLive -> MetricFlow.DataSync
      """

      assert {:ok, proposal} = Proposal.from_markdown(markdown, app_name: "MetricFlow")

      context = hd(proposal.contexts)
      assert length(context.children) == 2

      sync_job = Enum.find(context.children, &(&1.name == "MetricFlow.DataSync.SyncJob"))
      assert sync_job != nil

      # Nested names are preserved
      google_ads =
        Enum.find(context.children, &(&1.name == "MetricFlow.DataSync.DataProviders.GoogleAds"))

      assert google_ads != nil
      assert google_ads.description == "Pulls Google Ads metrics"
    end
  end
end
