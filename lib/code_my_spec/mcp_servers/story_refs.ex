defmodule CodeMySpec.McpServers.StoryRefs do
  @moduledoc """
  Story numbers at the tool boundary.

  Agents name a story by its number. Everything behind the tools — the graph,
  tasks, rules, issues — keys on the id. This is the one place the two meet:
  a number coming in becomes an id, and a story node going out carries its
  number.
  """

  alias CodeMySpec.Stories

  @doc "The story a number names in the scope's project."
  def fetch_story(scope, number) do
    case Stories.get_story_by_number(scope, number) do
      nil -> {:error, :story_not_found}
      story -> {:ok, story}
    end
  end

  @doc "The id behind an optional story number. `nil` stays `nil`."
  def story_id(_scope, nil), do: {:ok, nil}

  def story_id(scope, number) do
    with {:ok, story} <- fetch_story(scope, number), do: {:ok, story.id}
  end

  @doc "Swaps a `:story_number` in attrs for the story's `:story_id`."
  def put_story_id(scope, attrs) do
    case Map.pop(attrs, :story_number) do
      {nil, attrs} ->
        {:ok, attrs}

      {number, attrs} ->
        with {:ok, id} <- story_id(scope, number), do: {:ok, Map.put(attrs, :story_id, id)}
    end
  end

  @doc """
  A requirement's entity reference as the graph keys it. A story is named by
  its number; components and the project are already named by their id.
  """
  def entity_id(scope, "story", number) when not is_nil(number) do
    case Stories.get_story_by_number(scope, number) do
      nil -> nil
      story -> to_string(story.id)
    end
  end

  def entity_id(_scope, _type, id), do: id

  @doc "Puts `:entity_number` on each story node, for rendering."
  def number_nodes(scope, nodes) do
    numbers =
      Map.new(Stories.story_numbers(scope), fn {id, number} -> {to_string(id), number} end)

    Enum.map(nodes, &number_node(&1, numbers))
  end

  # A story's entity_id is an integer from the projection and text from the
  # shadow, so it is compared as text.
  defp number_node(%{entity_type: "story", entity_id: id} = node, numbers),
    do: Map.put(node, :entity_number, Map.get(numbers, to_string(id)))

  defp number_node(node, _numbers), do: node

  @doc """
  Numbers the story nodes an execution offers.

  A copy with no active story is offered work from every story it holds, so
  the execution's own `story` cannot say which number each node carries.
  """
  def number_execution(scope, %{wave: wave, actionable: actionable} = execution) do
    %{execution | wave: number_nodes(scope, wave), actionable: number_nodes(scope, actionable)}
  end

  @doc """
  How a node is named to an agent: a story by its number, anything else by its
  id. A story node that was never numbered raises rather than printing its id,
  which `start_task` would read as some other story's number.
  """
  def entity_ref(%{entity_type: "story", entity_number: number}) when is_integer(number),
    do: number

  def entity_ref(%{entity_type: "story"} = node),
    do: raise(ArgumentError, "story node #{node.name} was rendered without its number")

  def entity_ref(%{entity_id: id}), do: id
end
