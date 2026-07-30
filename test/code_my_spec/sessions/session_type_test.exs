defmodule CodeMySpec.Sessions.SessionTypeTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentTasks
  alias CodeMySpec.Sessions.SessionType

  # ============================================================================
  # Fixtures
  # ============================================================================

  defp valid_module_atoms do
    [
      AgentTasks.ArchitectureDesign,
      AgentTasks.CodeGeneration,
      AgentTasks.ComponentCode,
      AgentTasks.ComponentSpec,
      AgentTasks.ComponentTest,
      AgentTasks.ContextComponentSpecs,
      AgentTasks.ContextDesignReview,
      AgentTasks.ContextSpec,
      AgentTasks.ControllerSpec,
      AgentTasks.DesignUi,
      AgentTasks.Deploy,
      AgentTasks.DevelopContext,
      AgentTasks.DevelopController,
      AgentTasks.DevelopLiveContext,
      AgentTasks.DevelopLiveView,
      AgentTasks.DevopsSetup,
      AgentTasks.FixAllBddSpecs,
      AgentTasks.FixBddSpecs,
      AgentTasks.FixIssues,
      AgentTasks.LinkStoryComponent,
      AgentTasks.LiveContextSpec,
      AgentTasks.LiveViewSpec,
      AgentTasks.PersonaResearch,
      AgentTasks.ProjectSetup,
      AgentTasks.Release,
      AgentTasks.SpexBoundaryReady,
      AgentTasks.QaApp,
      AgentTasks.QaIntegrationPlan,
      AgentTasks.QaJourney,
      AgentTasks.QaSetup,
      AgentTasks.QaStory,
      AgentTasks.ResearchTopic,
      AgentTasks.StartImplementation,
      AgentTasks.StoryInterview,
      AgentTasks.TechnicalStrategy,
      AgentTasks.ThreeAmigos,
      AgentTasks.TriageIssues,
      AgentTasks.WriteBddSpecs
    ]
  end

  defp valid_string_names do
    [
      "ArchitectureDesign",
      "CodeGeneration",
      "ComponentCode",
      "ComponentSpec",
      "ComponentTest",
      "ContextComponentSpecs",
      "ContextDesignReview",
      "ContextSpec",
      "ControllerSpec",
      "DesignUi",
      "Deploy",
      "DevelopContext",
      "DevelopController",
      "DevelopLiveContext",
      "DevelopLiveView",
      "DevopsSetup",
      "FixAllBddSpecs",
      "FixBddSpecs",
      "FixIssues",
      "LinkStoryComponent",
      "LiveContextSpec",
      "LiveViewSpec",
      "PersonaResearch",
      "ProjectSetup",
      "Release",
      "SpexBoundaryReady",
      "QaApp",
      "QaIntegrationPlan",
      "QaJourney",
      "QaSetup",
      "QaStory",
      "ResearchTopic",
      "StartImplementation",
      "StoryInterview",
      "TechnicalStrategy",
      "ThreeAmigos",
      "TriageIssues",
      "WriteBddSpecs"
    ]
  end

  defp invalid_types do
    [
      "InvalidType",
      "UnknownTask",
      "NotAnAgentTask",
      "",
      123,
      nil,
      %{},
      [],
      :invalid_atom,
      SomeOtherModule
    ]
  end

  # ============================================================================
  # cast/1 Tests
  # ============================================================================

  describe "cast/1" do
    test "returns module atom for valid string name (e.g. \"ComponentSpec\" → AgentTasks.ComponentSpec)" do
      assert {:ok, AgentTasks.ComponentSpec} = SessionType.cast("ComponentSpec")
      assert {:ok, AgentTasks.ComponentCode} = SessionType.cast("ComponentCode")
      assert {:ok, AgentTasks.ComponentTest} = SessionType.cast("ComponentTest")
      assert {:ok, AgentTasks.ContextSpec} = SessionType.cast("ContextSpec")
      assert {:ok, AgentTasks.ContextComponentSpecs} = SessionType.cast("ContextComponentSpecs")
      assert {:ok, AgentTasks.ContextDesignReview} = SessionType.cast("ContextDesignReview")
      assert {:ok, AgentTasks.ArchitectureDesign} = SessionType.cast("ArchitectureDesign")
      assert {:ok, AgentTasks.ProjectSetup} = SessionType.cast("ProjectSetup")
      assert {:ok, AgentTasks.WriteBddSpecs} = SessionType.cast("WriteBddSpecs")
      assert {:ok, AgentTasks.FixAllBddSpecs} = SessionType.cast("FixAllBddSpecs")
      assert {:ok, AgentTasks.DevelopContext} = SessionType.cast("DevelopContext")
      assert {:ok, AgentTasks.DevelopLiveView} = SessionType.cast("DevelopLiveView")
      assert {:ok, AgentTasks.DesignUi} = SessionType.cast("DesignUi")
      assert {:ok, AgentTasks.TechnicalStrategy} = SessionType.cast("TechnicalStrategy")
      assert {:ok, AgentTasks.ResearchTopic} = SessionType.cast("ResearchTopic")
      assert {:ok, AgentTasks.DevelopLiveContext} = SessionType.cast("DevelopLiveContext")
      assert {:ok, AgentTasks.LiveContextSpec} = SessionType.cast("LiveContextSpec")
      assert {:ok, AgentTasks.QaApp} = SessionType.cast("QaApp")
      assert {:ok, AgentTasks.QaSetup} = SessionType.cast("QaSetup")
      assert {:ok, AgentTasks.QaStory} = SessionType.cast("QaStory")
      assert {:ok, AgentTasks.StartImplementation} = SessionType.cast("StartImplementation")
      assert {:ok, AgentTasks.TriageIssues} = SessionType.cast("TriageIssues")
      assert {:ok, AgentTasks.FixBddSpecs} = SessionType.cast("FixBddSpecs")
      assert {:ok, AgentTasks.FixIssues} = SessionType.cast("FixIssues")
      assert {:ok, AgentTasks.QaJourney} = SessionType.cast("QaJourney")
    end

    test "returns module atom for valid atom" do
      for module <- valid_module_atoms() do
        assert {:ok, ^module} = SessionType.cast(module)
      end
    end

    test "returns :error for unknown type" do
      for invalid <- invalid_types() do
        assert :error = SessionType.cast(invalid)
      end
    end
  end

  # ============================================================================
  # mapper/0 Tests
  # ============================================================================

  describe "mapper/0" do
    test "maps \"ComponentSpec\" to AgentTasks.ComponentSpec" do
      mapper = SessionType.mapper()
      assert mapper["ComponentSpec"] == AgentTasks.ComponentSpec
    end

    test "includes all valid agent task types" do
      mapper = SessionType.mapper()

      # Verify all expected string names are present
      for name <- valid_string_names() do
        assert Map.has_key?(mapper, name), "Expected mapper to include key: #{name}"
      end

      # Verify all expected module atoms are present as values
      mapper_values = Map.values(mapper)

      for module <- valid_module_atoms() do
        assert module in mapper_values, "Expected mapper to include module: #{inspect(module)}"
      end

      # Verify the mapper has exactly the expected number of entries
      assert map_size(mapper) == length(valid_module_atoms())
    end
  end

  describe "load/1 — tolerance for legacy rows" do
    # Regression guard for issue f79da343. A row whose `type` names a module
    # that no longer exists must still load: `load/1` is deliberately tolerant
    # while `cast/1` stays strict, so new writes are still rejected but a
    # legacy row cannot take down every query that materialises a Session.
    #
    # Without this, `Repo.all(Session)` crashes with
    #   ** (ArgumentError) cannot load "Elixir.CodeMySpec.ComponentDesignSessions"
    #      as type CodeMySpec.Sessions.SessionType
    # and the failure surfaces far from its cause — it took down the whole QA
    # submission path via an opaque -32603 from inside an Anubis tool dispatch.
    #
    # If someone "tightens" load/1 to to_existing_atom/1 for symmetry with
    # cast/1, this test is what should stop them.
    test "loads a type whose module no longer exists" do
      assert {:ok, _} = SessionType.load("Elixir.CodeMySpec.ComponentDesignSessions")
    end

    test "loads a type that was never a module at all" do
      assert {:ok, _} = SessionType.load("Elixir.CodeMySpec.AgentTasks.NeverExisted")
    end

    test "loads every currently valid type" do
      for module <- valid_module_atoms() do
        assert {:ok, ^module} = SessionType.load(Atom.to_string(module))
      end
    end

    test "cast/1 stays strict — a deleted module is still rejected on write" do
      # The asymmetry is the point: tolerate what is already on disk, refuse to
      # write more of it.
      assert :error = SessionType.cast("Elixir.CodeMySpec.ComponentDesignSessions")
    end
  end
end
