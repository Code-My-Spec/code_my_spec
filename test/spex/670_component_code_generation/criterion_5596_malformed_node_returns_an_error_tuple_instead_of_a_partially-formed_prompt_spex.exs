defmodule CodeMySpecSpex.Story670.Criterion5596Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5596 — Malformed node returns an error tuple instead of a
  partially-formed prompt.

  Surface caveat: production graph projection never produces malformed
  nodes — the projector controls every field. This spec asserts the
  defensive contract directly on `ComponentCode.orchestrate/1` rather
  than through `get_next_requirement`, because there is no surface
  path that yields a node missing one of `name`, `entity_type`,
  `entity_id`, or `entity_name`. The contract still belongs to the
  module: callers in `RequirementsMapper.orchestrate_node/1` rely on
  the `{:ok, prompt} | {:error, :invalid_node}` shape to fall back
  cleanly when an unexpected node ever does sneak through.

  Reads as a unit-level scenario for that reason; if a future surface
  exposes node assembly to less-trusted callers, this scenario should
  be re-driven through that surface.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.AgentTasks.ComponentCode

  spex "Component Code Generation" do
    scenario "Malformed node returns an error tuple instead of a partially-formed prompt" do
      then_ "missing name yields {:error, :invalid_node}", _context do
        node = %{name: nil, entity_type: "component", entity_id: "abc", entity_name: "Foo"}

        assert {:error, :invalid_node} = ComponentCode.orchestrate(node)

        {:ok, %{}}
      end

      and_ "missing entity_type yields {:error, :invalid_node}", _context do
        node = %{name: "implementation_file", entity_type: nil, entity_id: "abc", entity_name: "Foo"}

        assert {:error, :invalid_node} = ComponentCode.orchestrate(node)

        {:ok, %{}}
      end

      and_ "missing entity_id yields {:error, :invalid_node}", _context do
        node = %{name: "implementation_file", entity_type: "component", entity_id: nil, entity_name: "Foo"}

        assert {:error, :invalid_node} = ComponentCode.orchestrate(node)

        {:ok, %{}}
      end

      and_ "missing entity_name yields {:error, :invalid_node}", _context do
        node = %{name: "implementation_file", entity_type: "component", entity_id: "abc", entity_name: nil}

        assert {:error, :invalid_node} = ComponentCode.orchestrate(node)

        {:ok, %{}}
      end

      and_ "a fully-populated node yields {:ok, prompt} naming @code-writer", _context do
        node = %{
          name: "implementation_file",
          entity_type: "component",
          entity_id: "abc",
          entity_name: "Foo"
        }

        assert {:ok, prompt} = ComponentCode.orchestrate(node)
        assert prompt =~ "@code-writer"
        assert prompt =~ "implementation_file"
        assert prompt =~ "abc"
        assert prompt =~ "Foo"

        {:ok, %{}}
      end
    end
  end
end
