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

  # Reading, and writing what a QA run produces. Everything a QA agent files
  # against a story it is testing, and nothing that edits the story itself: a
  # QA agent that can rewrite a criterion can make a failing run pass without
  # anybody deciding to.
  @qa ~w(
    list_stories get_story list_story_titles show_story_requirements get_story_gherkin
    show_component_requirements show_architecture_overview
    list_requirements show_requirement list_personas get_persona
    list_issues get_issue create_issue accept_issue dismiss_issue resolve_issue
    list_qa_attempts submit_qa_result invalidate_qa_attempt
    list_knowledge read_knowledge semantic_search
    list_tasks list_session_subagents
    web_search web_fetch
  )

  # Writing code against a spec, and reading everything that says what the spec
  # is. No issue triage and no QA submission: a coding agent that can resolve
  # the issue it was given is grading its own work.
  @coding ~w(
    list_stories get_story list_story_titles show_story_requirements get_story_gherkin
    show_component_requirements show_architecture_overview
    create_component update_component validate_dependency_graph
    list_requirements show_requirement
    list_rules list_questions
    list_issues get_issue create_issue
    list_knowledge read_knowledge semantic_search refresh_embeddings
    read_project_file write_project_file
    list_tasks clear_problems list_problems
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
  The tools an agent of this type starts with, or `nil` for every tool there is.

  `:main` is `nil` rather than a list, and both halves of that are deliberate.

  It may call everything, because its job is the whole project and scoping it
  is scoping the thing that checks the others. And enumerating "everything" into
  a row would be a copy of the catalogue that goes stale the day a tool is
  added — the same argument this column's own migration makes for not
  backfilling one. A stale list would read as a scoping decision somebody made.

  `nil` already means "no restriction" everywhere it is read, so main shares a
  meaning with the rows that predate scoping. That is not a coincidence to be
  tidied away: both may call everything, and saying so twice in two shapes would
  be the ambiguity, not the fix.

  Which tools exist at all is the MCP layer's knowledge and stays there — this
  context is not allowed to ask, and should not want to.
  """
  @spec for_role(atom()) :: [String.t()] | nil
  def for_role(:main), do: nil
  def for_role(:qa), do: @qa
  def for_role(:coding), do: @coding
  def for_role(:product), do: @product
  def for_role(_role), do: []
end
