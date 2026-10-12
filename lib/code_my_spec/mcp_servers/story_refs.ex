defmodule CodeMySpec.McpServers.StoryRefs do
  @moduledoc """
  Story numbers at the tool boundary.

  Agents name a story by its number. Everything behind the tools — the graph,
  tasks, rules, issues — keys on the id. This is the one place the two meet:
  a number coming in becomes an id, and a story node going out carries its
  number.
  """

  alias CodeMySpec.Stories

  # Names agents reach for when they mean `story_number` (269c4d59). An alias
  # the tool declares itself is its own argument — `create_story`'s `story` is
  # the sentence — and is left alone.
  @aliases ~w(story_number story_id story entity_id)

  @doc """
  Arguments with the story named the canonical way.

  Every tool that names a story takes `story_number`. The older names
  (`story`, `story_id`, `entity_id`) are read as it where the tool does not
  declare them, and a numeric string is cast to the integer. A tool that
  scopes by `entity_type` + `entity_id` gets `story_number` translated into
  that pair. Applied before validation, on the direct and the script path.
  """
  @spec normalize_args(map() | nil, map()) :: map()
  def normalize_args(schema, args) when is_map(args) do
    props = Map.get(schema || %{}, "properties", %{})

    cond do
      Map.has_key?(props, "entity_id") and Map.has_key?(props, "entity_type") ->
        into_entity(args, props)

      Map.has_key?(props, "story_number") ->
        args |> into_story_number(props) |> cast_numbers(props)

      true ->
        cast_numbers(args, props)
    end
  end

  def normalize_args(_schema, args), do: args

  @doc "The same for a `tools/call` request, against the server's components."
  def normalize_request(
        %{"params" => %{"name" => name, "arguments" => args}} = request,
        components
      )
      when is_map(args) do
    case Enum.find(components, &(&1.name == name)) do
      nil -> request
      tool -> put_in(request, ["params", "arguments"], normalize_args(tool.input_schema, args))
    end
  end

  def normalize_request(request, _components), do: request

  defp into_story_number(args, props) do
    {found, args} = pop_aliases(args, props)

    case {Map.get(args, "story_number"), found} do
      {nil, [value | _]} -> Map.put(args, "story_number", value)
      _ -> args
    end
  end

  # `story_number` is declared on these for the docs, and always becomes the
  # pair the tool reads.
  defp into_entity(args, props) do
    {found, args} = pop_aliases(args, Map.delete(props, "story_number"))

    case {Map.get(args, "entity_id"), found} do
      {nil, [value | _]} ->
        args
        |> Map.put("entity_id", to_string(value))
        |> Map.put_new("entity_type", "story")

      _ ->
        args
    end
  end

  # Aliases the tool does not declare, in preference order, removed from args.
  defp pop_aliases(args, declared) do
    Enum.reduce(@aliases, {[], args}, fn name, {found, acc} ->
      if Map.has_key?(declared, name) or not Map.has_key?(acc, name) do
        {found, acc}
      else
        {value, acc} = Map.pop(acc, name)
        {if(is_nil(value), do: found, else: found ++ [value]), acc}
      end
    end)
  end

  defp cast_numbers(args, props) do
    Enum.reduce(~w(story_number target_story_number), args, fn name, acc ->
      with %{"type" => "integer"} <- Map.get(props, name),
           value when is_binary(value) <- Map.get(acc, name),
           {number, ""} <- Integer.parse(String.trim(value)) do
        Map.put(acc, name, number)
      else
        _ -> acc
      end
    end)
  end

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

  defdelegate number_nodes(scope, nodes), to: CodeMySpec.Requirements.Directives
  defdelegate number_execution(scope, execution), to: CodeMySpec.Requirements.Directives
  defdelegate entity_ref(node), to: CodeMySpec.Requirements.Directives
end
