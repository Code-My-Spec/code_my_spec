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
    test "returns ok for valid proposal" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.Verification", description: "Test", children: [], story_ids: [1]}
        ]
      })

      assert {:ok, ^proposal} = Proposal.validate(proposal)
    end

    test "returns error for invalid module names" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "invalid_name", description: "Test", children: [], story_ids: [1]}
        ]
      })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :invalid_naming))
    end

    test "returns error for duplicate names" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.Verification", description: "Test", children: [], story_ids: [1]},
          %{name: "Fuellytics.Verification", description: "Duplicate", children: [], story_ids: [2]}
        ]
      })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :duplicate_names))
    end

    test "returns error for empty contexts" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.Empty", description: "Empty context", children: [], story_ids: []}
        ]
      })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :empty_contexts))
    end

    test "returns error for circular dependencies" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.A", description: "A", children: [], story_ids: [1]},
          %{name: "Fuellytics.B", description: "B", children: [], story_ids: [2]}
        ],
        dependencies: [
          %{from: "Fuellytics.A", to: "Fuellytics.B"},
          %{from: "Fuellytics.B", to: "Fuellytics.A"}
        ]
      })

      assert {:error, errors} = Proposal.validate(proposal)
      assert Enum.any?(errors, &(&1.type == :dependency_cycle))
    end

    test "checks story coverage when story_ids provided" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.A", description: "A", children: [], story_ids: [1, 2]}
        ]
      })

      # Story 3 is not mapped
      assert {:error, errors} = Proposal.validate(proposal, story_ids: [1, 2, 3])
      assert Enum.any?(errors, &(&1.type == :unmapped_stories))
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
              %{name: "Transaction", type: "schema", description: "Transaction schema"}
            ],
            story_ids: [1]
          }
        ],
        surface_components: [
          %{name: "FuellyticsWeb.DashboardLive", type: "liveview", description: "Dashboard", story_ids: [2]}
        ]
      })

      components = Proposal.to_components(proposal)

      assert length(components) == 3  # context + child + surface

      # Check context
      context = Enum.find(components, &(&1.module_name == "Fuellytics.Verification"))
      assert context.type == "context"

      # Check child
      child = Enum.find(components, &(&1.module_name == "Fuellytics.Verification.Transaction"))
      assert child.type == "schema"
      assert child.parent_module == "Fuellytics.Verification"

      # Check surface
      surface = Enum.find(components, &(&1.module_name == "FuellyticsWeb.DashboardLive"))
      assert surface.type == "liveview"
    end
  end

  describe "to_mermaid/1" do
    test "generates valid mermaid diagram" do
      proposal = Proposal.new(%{
        app_name: "Fuellytics",
        contexts: [
          %{name: "Fuellytics.Verification", description: "Verification", children: [], story_ids: [1]}
        ],
        surface_components: [
          %{name: "FuellyticsWeb.DashboardLive", type: "liveview", description: "Dashboard"}
        ],
        dependencies: [
          %{from: "FuellyticsWeb.DashboardLive", to: "Fuellytics.Verification"}
        ]
      })

      mermaid = Proposal.to_mermaid(proposal)

      assert String.contains?(mermaid, "flowchart TD")
      assert String.contains?(mermaid, "Fuellytics_Verification")
      assert String.contains?(mermaid, "FuellyticsWeb_DashboardLive")
      assert String.contains?(mermaid, "-->")
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
              %{name: "Transaction", type: "schema", description: "Transaction"}
            ],
            story_ids: [1]
          }
        ]
      })

      # We can test dry_run without a scope since it doesn't actually create anything
      assert {:ok, result} = Proposal.execute(proposal, nil, dry_run: true)

      assert result.created_contexts == 1
      assert result.created_components == 2  # context + child
      assert result.linked_stories == 1
      assert length(result.components) == 2
    end
  end
end
