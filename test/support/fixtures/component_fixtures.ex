defmodule CodeMySpec.ComponentsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CodeMySpec.Components` context.
  """

  alias CodeMySpec.Architecture.SpecStub
  alias CodeMySpec.Components.Dependency
  alias CodeMySpec.Components
  alias CodeMySpec.Repo

  @doc """
  Generate a component.
  """
  def component_fixture(scope, attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        name: "TestComponent#{unique_id}",
        type: "context",
        module_name: "TestComponent#{unique_id}",
        description: "A test component"
      })

    {:ok, component} = Components.create_component(scope, attrs)
    component
  end

  @doc """
  Generate a stub component — creates a DB row AND writes a stub spec file
  at the conventional path through the scope's environment.

  Mirrors the behavior of the `create_component` MCP tool. Use this in tests
  that need a pre-existing component with its spec stub already on disk
  (e.g. patch-mode scenarios where the architect has previously stubbed
  components and is now linking stories or filling specs in).
  """
  def stub_component_fixture(scope, attrs \\ %{}) do
    component = component_fixture(scope, attrs)
    :ok = SpecStub.write_for_scope(scope, component)
    component
  end

  @doc """
  Generate multiple components for testing relationships.
  """
  def component_with_dependencies_fixture(scope, attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    parent_attrs =
      Map.merge(
        %{
          name: "ParentComponent#{unique_id}",
          type: "context",
          module_name: "ParentComponent#{unique_id}"
        },
        attrs
      )

    child_attrs = %{
      name: "ChildComponent#{unique_id}",
      type: "schema",
      module_name: "ChildComponent#{unique_id}"
    }

    {:ok, parent} = Components.create_component(scope, parent_attrs)
    {:ok, child} = Components.create_component(scope, child_attrs)

    # Create dependency relationship directly via changeset
    %Dependency{}
    |> Dependency.changeset(%{
      source_component_id: parent.id,
      target_component_id: child.id
    })
    |> Repo.insert!()

    {parent, child}
  end

  @doc """
  Generate a genserver component.
  """
  def genserver_component_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "TestGenServer",
        type: "genserver",
        module_name: "TestGenServer",
        description: "A test GenServer"
      })

    component_fixture(scope, attrs)
  end

  @doc """
  Generate a schema component.
  """
  def schema_component_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "TestSchema",
        type: "schema",
        module_name: "TestSchema",
        description: "A test schema"
      })

    component_fixture(scope, attrs)
  end

  @doc """
  Generate a repository component.
  """
  def repository_component_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "TestRepository",
        type: "repository",
        module_name: "TestRepository",
        description: "A test repository"
      })

    component_fixture(scope, attrs)
  end
end
