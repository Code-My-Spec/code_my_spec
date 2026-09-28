defmodule CodeMySpecSpex.CriterionScript do
  @moduledoc """
  Drives the story and criterion tools the way an agent does: by name,
  through `run_script`.

  By name rather than by tool module, because some of the tools these spex
  describe (`retire_criterion`, `restore_criterion`, `get_criterion`) do not
  exist until the story that asks for them is built. A missing tool comes back
  as a failed call the spex can report, not as a module that does not compile.

  Story and criterion numbers are read off the text the agent reads —
  `Story N` and `(criterion N)` in `get_story` — because those are the only
  numbers the agent ever sees.
  """

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  @doc "Run a Lua script as the agent. Returns `%{error?: boolean, text: String.t()}`."
  def run(scope, script) do
    frame = %Frame{assigns: %{current_scope: scope}}
    {:reply, response, _frame} = RunScript.execute(%{script: script}, frame)
    %{error?: response.isError == true, text: response_text(response)}
  end

  @doc """
  Create a released story with one criterion per description, in order.
  Returns the story's number.
  """
  def create_story(scope, title, descriptions) do
    adds =
      Enum.map_join(descriptions, "\n", fn description ->
        "add_criterion({ story_number = n, description = #{lua_string(description)} })"
      end)

    %{text: text} =
      run(scope, """
      local created = create_story({ title = #{lua_string(title)}, story = "As an agent, I want this so that that." })
      local n = tonumber(created:match("^Story (%d+) created"))
      update_story({ story_number = n, ready_for_dev = true })
      #{adds}
      return "story=" .. n
      """)

    case Regex.run(~r/story=(\d+)/, text) do
      [_, n] -> String.to_integer(n)
      _ -> raise "could not create story #{inspect(title)}: #{text}"
    end
  end

  @doc "What the agent reads for a story."
  def story_text(scope, number),
    do: run(scope, "return get_story({ story_number = #{number} })").text

  @doc "The criterion numbers `get_story` shows, in order."
  def numbers(text) do
    ~r/\(criterion (\d+)\)/
    |> Regex.scan(text)
    |> Enum.map(fn [_, n] -> String.to_integer(n) end)
  end

  @doc "The story's number, off the `Story N:` in `get_story`'s heading."
  def story_number(text) do
    [_, n] = Regex.run(~r/## Story (\d+):/, text)
    String.to_integer(n)
  end

  @doc """
  A valid spex file. `criterion: n` names the criterion it covers; `nil`
  writes one that names none.
  """
  def spex_naming(number, module \\ "Sample") do
    opts = if number, do: ", criterion: #{number}", else: ""

    """
    defmodule CodeMySpecSpex.#{module}Spex do
      use CodeMySpecSpex.Case

      spex "It happens"#{opts} do
        scenario "it happens" do
          given_ "a state", context do
            {:ok, context}
          end

          when_ "an action", context do
            {:ok, context}
          end

          then_ "an outcome", context do
            {:ok, context}
          end
        end
      end
    end
    """
  end

  @doc "What `show_requirement` tells the agent about a story's `bdd_specs_exist`."
  def specs_requirement(scope, number) do
    run(scope, """
    return show_requirement({ name = "bdd_specs_exist", entity_type = "story", entity_id = "#{number}" })
    """).text
  end

  @doc "Whether `show_requirement` reports the story's specs as existing."
  def specs_exist?(scope, number),
    do: specs_requirement(scope, number) =~ "**Status:** Satisfied"

  @doc "A Lua string literal for `value`."
  def lua_string(value), do: "[==[" <> to_string(value) <> "]==]"
end
