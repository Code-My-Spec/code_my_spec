defmodule CodeMySpec.Architecture.ProposalTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.Architecture.Proposal

  describe "new/1" do
    test "creates proposal from map with atom keys" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.Verification", description: "Verification context", children: [], story_ids: [1, 2]}
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
      proposal = Proposal.new(%{
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
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{
            name: "Fuellytics.Verification",
            description: "Test",
            children: [%{name: "Fuellytics.Verification.Transaction", type: "schema", story_ids: [1]}]
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
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "invalid_name", description: "Test", children: [%{name: "invalid_name.X", type: "schema"}]}
        ]
      })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :invalid_naming))
    end

    test "returns error for duplicate names" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.Verification", description: "Test", children: [%{name: "Fuellytics.Verification.X", type: "schema"}]},
          %{name: "Fuellytics.Verification", description: "Duplicate", children: [%{name: "Fuellytics.Verification.Y", type: "schema"}]}
        ]
      })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :duplicate_names))
    end

    test "returns error for circular dependencies" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.A", description: "A", children: [%{name: "Fuellytics.A.X", type: "schema"}]},
          %{name: "Fuellytics.B", description: "B", children: [%{name: "Fuellytics.B.Y", type: "schema"}]}
        ],
        dependencies: [
          %{from: "Fuellytics.A", to: "Fuellytics.B"},
          %{from: "Fuellytics.B", to: "Fuellytics.A"}
        ]
      })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :dependency_cycle))
    end

    test "requires dual story mapping - each story needs both surface and context" do
      # Story mapped to surface but not context
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.A", description: "A", children: [%{name: "Fuellytics.A.X", type: "schema"}]}
        ],
        surface_components: [
          %{name: "FuellyticsWeb.DashboardLive", type: "liveview", story_ids: [1, 2]}
        ]
      })

      assert {:error, errors} = Proposal.validate(proposal, story_ids: [1, 2])
      assert Enum.any?(errors, &(&1.type == :stories_missing_context))
    end

    test "requires stories to be mapped to surface components" do
      # Story mapped to context but not surface
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.A", description: "A", children: [%{name: "Fuellytics.A.X", type: "schema", story_ids: [1, 2]}]}
        ],
        surface_components: [
          %{name: "FuellyticsWeb.DashboardLive", type: "liveview"}
        ]
      })

      assert {:error, errors} = Proposal.validate(proposal, story_ids: [1, 2])
      assert Enum.any?(errors, &(&1.type == :stories_missing_surface))
    end

    test "accepts stories mapped to both surface and context" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.A", description: "A", children: [%{name: "Fuellytics.A.X", type: "schema", story_ids: [1, 2]}]}
        ],
        surface_components: [
          %{name: "FuellyticsWeb.DashboardLive", type: "liveview", story_ids: [1, 2]}
        ]
      })

      assert {:ok, _} = Proposal.validate(proposal, story_ids: [1, 2])
    end

    test "accepts stories mapped to context itself (not just children)" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.A", description: "A", story_ids: [1], children: [%{name: "Fuellytics.A.X", type: "schema"}]}
        ],
        surface_components: [
          %{name: "FuellyticsWeb.DashboardLive", type: "liveview", story_ids: [1]}
        ]
      })

      assert {:ok, _} = Proposal.validate(proposal, story_ids: [1])
    end

    test "returns error for child not starting with parent context name" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.Verification", description: "Test", children: [%{name: "Transaction", type: "schema"}]}
        ],
        surface_components: [
          %{name: "FuellyticsWeb.DashboardLive", type: "liveview", story_ids: [1]}
        ]
      })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :invalid_naming_hierarchy))
    end

    test "returns error for context not starting with app name" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Verification", description: "Test", children: [%{name: "Verification.Transaction", type: "schema"}]}
        ],
        surface_components: [
          %{name: "FuellyticsWeb.DashboardLive", type: "liveview", story_ids: [1]}
        ]
      })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :invalid_naming_hierarchy))
    end

    test "returns error for surface component not starting with app web name" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.Verification", description: "Test", children: [%{name: "Fuellytics.Verification.Transaction", type: "schema"}]}
        ],
        surface_components: [
          %{name: "DashboardLive", type: "liveview", story_ids: [1]}
        ]
      })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :invalid_naming_hierarchy))
    end
  end

  describe "to_components/1" do
    test "returns all components from contexts and surface" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{
            name: "Fuellytics.Verification",
            description: "Verification context",
            children: [
              %{name: "Fuellytics.Verification.Transaction", type: "schema", description: "Transaction schema"}
            ]
          }
        ],
        surface_components: [
          %{name: "FuellyticsWeb.DashboardLive", type: "liveview", description: "Dashboard", story_ids: [1, 2]}
        ]
      })

      components = Proposal.to_components(proposal)

      assert length(components) == 3  # context + child + surface

      # Check context
      context = Enum.find(components, &(&1.module_name == "Fuellytics.Verification"))
      assert context.type == "context"

      # Check child - name is used directly (fully qualified)
      child = Enum.find(components, &(&1.module_name == "Fuellytics.Verification.Transaction"))
      assert child.type == "schema"
      assert child.parent_module == "Fuellytics.Verification"

      # Check surface
      surface = Enum.find(components, &(&1.module_name == "FuellyticsWeb.DashboardLive"))
      assert surface.type == "liveview"
    end
  end

  describe "execute/3 with dry_run" do
    test "returns preview without creating files" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{
            name: "Fuellytics.Verification",
            description: "Verification",
            children: [
              %{name: "Fuellytics.Verification.Transaction", type: "schema", description: "Transaction"}
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
      assert result.created_components == 3  # context + child + surface
      assert result.linked_stories == 1
      assert length(result.components) == 3
    end
  end
end
