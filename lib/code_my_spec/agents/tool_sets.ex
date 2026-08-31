defmodule CodeMySpec.Agents.ToolSets do
  @moduledoc """
  Which tools an agent may call, as a list.

  Story 982. The obvious shape was to scope by role — ask the agent's type at
  call time and decide from it — and John's call was the other one: the agent
  carries an explicit list, and the role only chooses which list it starts with.

  The difference shows up the first time somebody wants an exception. A QA agent
  that needs one extra tool for one project is a new role under the implicit
  scheme, or a `case` inside the check; under this one it is a different list on
  one row. It also makes the answer readable: "what may this agent call" is a
  column, not a function of a column and a table somewhere else.

  ## The lists are a judgement, and they will age

  Kept here, one per role, so changing our mind is editing a list rather than
  hunting for a rule — the same argument `Agents.Defaults` makes about models,
  and for the same reason.

  `:main` is deliberately everything. Its job is the whole project — shaping
  stories, organising epics, handing work over, checking what came back — so
  scoping it is scoping the thing that checks the others.
  """

  alias CodeMySpec.McpServers.ScriptableTools

  # Reading, and writing what a QA run produces. Everything a QA agent files
  # against a story it is testing, and nothing that edits the story itself: a
  # QA agent that can rewrite a criterion can make a failing run pass without
  # anybody deciding to.
  @qa ~w(
    list_stories get_story list_story_titles show_story_requirements get_story_gherkin
    list_components show_component_requirements show_architecture_overview
    list_requirements show_requirement list_personas get_persona
    list_issues get_issue create_issue accept_issue dismiss_issue resolve_issue
    list_qa_attempts submit_qa_result invalidate_qa_attempt
    list_knowledge read_knowledge semantic_search
    list_tasks list_session_subagents sync_project
    web_search web_fetch
  )

  # Writing code against a spec, and reading everything that says what the spec
  # is. No issue triage and no QA submission: a coding agent that can resolve
  # the issue it was given is grading its own work.
  @coding ~w(
    list_stories get_story list_story_titles show_story_requirements get_story_gherkin
    list_components show_component_requirements show_architecture_overview
    create_component update_component validate_dependency_graph
    list_requirements show_requirement
    list_rules list_questions
    list_issues get_issue create_issue
    list_knowledge read_knowledge semantic_search refresh_embeddings
    read_project_file write_project_file
    list_tasks sync_project clear_problems list_problems
    web_search web_fetch
  )

  # Shaping what gets built, and never building it. The product half of the
  # graph: stories, criteria, rules, personas, epics.
  @product ~w(
    list_stories get_story list_story_titles create_story update_story delete_story
    add_criterion update_criterion delete_criterion move_criterion
    add_rule update_rule delete_rule add_scenario update_scenario
    add_question resolve_question list_rules list_questions
    link_criterion_to_rule start_three_amigos_session start_story_interview
    start_story_review get_story_gherkin show_story_requirements
    list_personas get_persona create_persona update_persona delete_persona
    link_persona_to_story unlink_persona_from_story
    list_epics create_epic update_epic assign_story_to_epic set_epic_stories_ready
    propose_epic tag_stories list_project_tags analyze_stories
    list_issues get_issue create_issue triage_issues
    list_knowledge read_knowledge semantic_search
    web_search web_fetch
  )

  @doc """
  The tools an agent of this type starts with.

  `:main` is every tool there is, read from the server's own list rather than
  written out — a copy here would go stale the day a tool is added, and the
  staleness would look like a scoping decision somebody made.
  """
  @spec for_role(atom()) :: [String.t()]
  def for_role(:main), do: all()
  def for_role(:qa), do: @qa
  def for_role(:coding), do: @coding
  def for_role(:product), do: @product
  def for_role(_role), do: []

  @doc "Every tool the server exposes."
  @spec all() :: [String.t()]
  def all, do: Enum.map(ScriptableTools.__components__(), & &1.name())
end
