defmodule CodeMySpecSpex.StoryDependencyScript do
  @moduledoc """
  Drives story 1125's tools the way an agent does: by name, through
  `run_script`, so a tool that does not exist yet is a failed call the spex
  report rather than a module that does not compile.

  The surface these spex name (story 1125 does not fix it, the spex do):

    * `add_story_dependency({ story_number, builds_on })`
    * `remove_story_dependency({ story_number, builds_on })`
    * `add_criterion` / `retire_criterion` answer a change to a story others
      build on with a warning naming the dependents and offering a follow-up
      story; passing `proceed = true` makes the change anyway.
    * `get_story` shows `Builds on` and `Built on by`, each entry as
      `Story N: Title (status)`.
  """

  alias CodeMySpecSpex.CriterionScript

  @doc "A released story with one criterion; returns its number."
  def story(scope, title),
    do: CriterionScript.create_story(scope, title, ["#{title} does its thing"])

  @doc "Record that story `number` builds on story `builds_on`."
  def link(scope, number, builds_on) do
    CriterionScript.run(scope, """
    local result, err = add_story_dependency({ story_number = #{number}, builds_on = #{builds_on} })
    if err then error(err.message) end
    return result
    """)
  end

  @doc "Remove the link from story `number` to story `builds_on`."
  def unlink(scope, number, builds_on) do
    CriterionScript.run(scope, """
    local result, err = remove_story_dependency({ story_number = #{number}, builds_on = #{builds_on} })
    if err then error(err.message) end
    return result
    """)
  end

  @doc "Add a criterion to a story; `proceed: true` makes it despite a warning."
  def add_criterion(scope, number, description, opts \\ []) do
    proceed = if Keyword.get(opts, :proceed, false), do: ", proceed = true", else: ""

    CriterionScript.run(scope, """
    return add_criterion({ story_number = #{number}, description = #{CriterionScript.lua_string(description)}#{proceed} })
    """)
  end

  @doc "Retire criterion `criterion` (its number is the project's, from get_story)."
  def retire_criterion(scope, criterion) do
    CriterionScript.run(scope, """
    return retire_criterion({ criterion_number = #{criterion} })
    """)
  end

  @doc "Rename a story."
  def rename(scope, number, title) do
    CriterionScript.run(scope, """
    return update_story({ story_number = #{number}, title = #{CriterionScript.lua_string(title)} })
    """)
  end

  @doc "What the agent reads for a story."
  defdelegate text(scope, number), to: CriterionScript, as: :story_text

  @doc "The lines of `text` under the `heading` (up to the next blank line)."
  def section(text, heading) do
    case Regex.run(~r/#{heading}:?\**\s*\n((?:.+\n?)+)/, text) do
      [_, body] -> body
      _ -> ""
    end
  end
end
