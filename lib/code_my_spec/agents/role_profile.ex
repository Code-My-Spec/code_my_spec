defmodule CodeMySpec.Agents.RoleProfile do
  @moduledoc """
  What each role is, as one data definition per role.

  Role behaviour used to be decided wherever it was needed, by matching on the
  role atom: the role list alone had seven copies, and each one could drift from
  the others without anything failing. Every role-conditional site reads its
  profile here instead, so reshaping a role is editing one entry.

  Its own boundary, depending on nothing, because the contexts below `Agents` —
  `Requirements` (which requirements a role is offered), `Validation` (whether
  problems hold it) — need the answer and must not depend on `Agents` to get it.
  It is also a compile-time dependency of the schemas that use `roles/0` as
  `Ecto.Enum` values, so it stays pure data.

  ## Fields

    * `requirements` — which requirements the role is offered, as selectors
      `Requirements` interprets. `:tagged` is every requirement whose definition
      names this role; `:untagged` every one that names no role.
    * `scope` — what the role works across. `:project` reads its copy's story,
      as a session does. `:story` and `:epic` read the agent's own `story_id`
      and are confined to it until it is complete; only a `:story` role is
      assigned a story of its epic by claiming its work (a31f1cd6).
    * `story_vantage` — whose stories its requirements are read on. `:copy`
      reads the stories its checkout can see; `:project` reads every story in
      the project wherever it is placed, each at its placement copy's verdict
      (a31f1cd6 step 4d).
    * `home_copy` — `:main` for the roles that live on the project's main
      checkout, `:feature` for the ones that staff a working copy. Only a
      `:main` role may start on the main copy.
    * `wake` — the `Agents.Wake` event kinds it is woken by, beyond those
      relevant to everyone (a person's message, replies to its own requests):
      `:work_offer` (the graph), `:nudge` (its turn-end review), `:resume`
      (a task it holds with no turn open), `:teammate_question` (questions
      other agents raised that it answers first), `:findings` (analysis
      findings nobody asked it for), `:cadence` (the main agent's check-in
      timer) and `:teammate_stalled` / `:teammate_died` (a teammate stalled,
      died or was reaped).
    * `waiting_on` — role-specific waits, each with the `Agents.Waiting`
      paths it holds. `:question_pending` is its own unanswered question.
    * `questions_block?` — whether an open question on its story blocks its
      story work.
    * `questions_to` — who its own questions go to first: `:main` or `:user`.
    * `tools` — `:all`, or the explicit list it may call.
    * `browses?` — whether its machine's browser tools are added to its list.
    * `holds_problems?` — whether a broken tree holds it (it can fix one).
    * `model_preference` — providers and models, most preferred first.
  """

  use Boundary, top_level?: true, deps: [], exports: :all

  @enforce_keys [
    :role,
    :requirements,
    :scope,
    :story_vantage,
    :home_copy,
    :wake,
    :waiting_on,
    :questions_block?,
    :questions_to,
    :tools,
    :browses?,
    :holds_problems?,
    :claims_any?,
    :model_preference
  ]
  defstruct @enforce_keys

  @type role :: :main | :product | :coding | :qa

  @type wake ::
          :work_offer
          | :nudge
          | :resume
          | :teammate_question
          | :findings
          | :cadence
          | :teammate_stalled
          | :teammate_died

  @type t :: %__MODULE__{
          role: role(),
          requirements: [:tagged | :untagged],
          scope: :project | :epic | :story,
          story_vantage: :copy | :project,
          home_copy: :main | :feature,
          wake: [wake()],
          waiting_on: [{:question_pending, [:turn_end | :offer | :resume]}],
          questions_block?: boolean(),
          questions_to: :main | :user,
          tools: :all | [String.t()],
          browses?: boolean(),
          holds_problems?: boolean(),
          claims_any?: boolean(),
          model_preference: [{String.t(), String.t()}]
        }

  # Reading, and writing what a QA run produces. Everything a QA agent files
  # against a story it is testing, and nothing that edits the story itself: a
  # QA agent that can rewrite a criterion can make a failing run pass without
  # anybody deciding to.
  #
  # `browser` is a capability, not a tool. The machine publishes 85 browser
  # tools and their names are its business, so the grant is "may drive the
  # browser" — see `McpServers.CodeMode.browser_capability/0`. Without it a QA
  # agent's browser sandbox binds nothing, which is what it did until
  # 2026-09-07: an agent whose whole job is browser testing, with a machine
  # reporting `ready`, calling into an empty catalog.
  # `call_mcp_server` is an instrument, not a capability, and that distinction is
  # the whole reason it is here rather than the three fleet tools a QA session
  # asked for in `50eac6ab`. Granting the tools under test would have grown this
  # list once per story and tested each tool's own dispatch rather than the
  # surface it is mounted on. Granting the client tests the surface as a caller.
  # John's call, 2026-09-15.
  #
  # `read_project_file`/`write_project_file` because all three of QA's own
  # project requirements are `path_exists` checks on files QA writes:
  # `qa_setup` wants `.code_my_spec/qa/plan.md`, and `qa_journey_plan` and
  # `qa_journey_execute` want their two docs beside it. The role carried
  # no file tool of any kind, so it could not satisfy a single one of them —
  # `submit_qa_result` files a verdict on a story and writes nothing to disk.
  #
  # Found the same day and the same way as `install_credo_checks` above: the
  # chain reached `qa_setup`, and the only thing standing between the agent and
  # its own requirement was a tool nobody had given it. Two roles, one bug —
  # which is the argument for checking every role's set against the
  # requirements that name it rather than against the last agent that
  # complained.
  @qa_tools ~w(
    list_stories get_story list_story_titles show_story_requirements get_story_gherkin
    show_component_requirements show_architecture_overview
    list_requirements show_requirement list_personas get_persona
    list_issues get_issue create_issue accept_issue dismiss_issue resolve_issue
    list_qa_attempts submit_qa_result invalidate_qa_attempt
    withdraw_question
    call_mcp_server
    list_knowledge read_knowledge semantic_search
    read_project_file write_project_file
    list_tasks list_session_subagents list_notifications
    web_search web_fetch
    browser
    query_logs get_trace slow_spans error_summary
  )

  # Writing code against a spec, and reading everything that says what the spec
  # is. No issue *triage* and no QA submission — deciding whether an incoming
  # issue is real is product's, and a coding agent that can submit a QA result
  # is grading its own work.
  #
  # `resolve_issue` is the exception, and it used to be excluded by the same
  # sentence. `issues_resolved` is coding's requirement and `FixIssues` tells it
  # to call `resolve_issue` per issue, so the rule and the graph contradicted
  # each other and the graph is the one with work hanging off it. John's call,
  # 2026-09-07.
  #
  # It is not self-grading in the way submitting a QA result is: resolving
  # records "I fixed this", and QA re-tests independently and can invalidate it.
  # What coding still cannot do is decide an issue was never real — `accept_issue`
  # and `dismiss_issue` stay product's.
  #
  # `create_issue` belongs here for the reverse reason, and has all along: an
  # agent working one thing finds another, and the choice has to be "write it
  # down and carry on" rather than "fix it now or lose it". John: "the coding
  # agent can also find issues that it should report and not fix right that
  # second."
  #
  # `browser` for the same reason QA has it: work on a LiveView is checked by
  # looking at it, and the `code-writer` agent type has carried browser tools
  # since before roles existed. Product does not — it writes specs, and a spec
  # is not verified by driving a page.
  # `promote` is deliberately NOT in this list, and the mistake is worth
  # recording because it looked right.
  #
  # These lists are the allowlist for *scriptable* tools — `tool_sets_test.exs`
  # checks every name here against `ScriptableTools`, and a name that matches
  # nothing "is not a smaller grant, it is a list that reads as bigger than it
  # is". `promote` is direct-only on `LocalServer`, so adding it here granted
  # exactly nothing while reading as though it had.
  #
  # What an agent in our own BEAM actually carries is the module list in
  # `CmsHarness.Agents.Engine.tools/1`, and that is where `promote` belongs and
  # now is. A coding agent spent two rounds reporting `Unknown tool: promote`
  # between the grant that did nothing and the one that worked.
  # `install_credo_checks` is coding's because `spex_boundary_ready` is coding's.
  #
  # The requirement asks for framework Credo checks on disk and the tool that
  # installs them was in no role's set at all — registered, reachable by
  # nobody. A coding agent worked the task properly, read the workflow and the
  # spex philosophy, called it, and was told "it exists, and this kind of agent
  # is not given it". It cancelled the task and stopped, which is exactly what
  # the rules ask of an agent facing a missing tool, and the chain stopped with
  # it. Measured 2026-09-22 on the math project's first autonomous run.
  #
  # The same shape as the `triage_issues` case below: a task prompt naming a
  # tool the role that receives it cannot call.
  @coding_tools ~w(
    list_stories get_story list_story_titles show_story_requirements get_story_gherkin
    show_component_requirements show_architecture_overview get_component
    create_component update_component validate_dependency_graph set_story_component
    add_dependency remove_dependency
    list_requirements show_requirement
    list_rules list_questions withdraw_question
    list_issues get_issue create_issue resolve_issue
    list_knowledge read_knowledge semantic_search
    read_project_file write_project_file
    list_tasks clear_problems list_problems
    install_credo_checks
    web_search web_fetch
    browser
    promote
    ensure_app_running restart_app stop_app
    query_logs get_trace slow_spans error_summary
  )

  # Shaping what gets built, and never building it. The product half of the
  # graph: stories, criteria, rules, personas, epics.
  #
  # Triage *is* shaping: `issues_triaged` is product's own requirement, and an
  # incoming issue is either work somebody has to plan or noise to throw away.
  # `accept_issue` and `dismiss_issue` are how that decision is recorded, and
  # they were missing — while `triage_issues`, which product does carry, hands
  # back a prompt naming them five times.
  #
  # So the agent was told to do a thing with a tool it did not have. It read all
  # four incoming issues, decided every one of them, and then had to tap out:
  # "This product agent lacks the required accept/dismiss tools, so I requested
  # tap-out for a role with triage authority." The work was done and could not
  # be written down.
  #
  # Note what this is not: `resolve_issue` stays off *this* list. Deciding
  # whether an issue is real is product's; declaring it fixed belongs to whoever
  # fixed it, which is coding — see the coding comment.
  #
  # `delete_component` beside create and update (856b3632): product shapes the
  # architecture, and a component it decided against had no way out of it.
  # `add_dependency` and `remove_dependency` for the same reason (3aeb66cf):
  # the edges are authored records too, not something a spec file has to carry.
  #
  # No staffing: making, offboarding and looping working copies is main's
  # (John, step 4c).
  @product_tools ~w(
    list_stories get_story list_story_titles create_story update_story retire_story restore_story
    add_criterion update_criterion retire_criterion restore_criterion get_criterion move_criterion
    add_rule update_rule delete_rule add_scenario update_scenario
    add_question resolve_question list_rules list_questions
    list_working_copies assign_epic_to_working_copy
    link_criterion_to_rule start_three_amigos_session start_story_interview
    start_story_review get_story_gherkin show_story_requirements
    list_personas get_persona create_persona update_persona delete_persona
    link_persona_to_story unlink_persona_from_story
    list_epics create_epic update_epic assign_story_to_epic set_epic_stories_ready
    propose_epic tag_stories list_project_tags analyze_stories
    set_story_component create_component update_component delete_component
    add_dependency remove_dependency
    validate_dependency_graph execute_proposal show_architecture_overview get_component
    list_issues get_issue create_issue triage_issues accept_issue dismiss_issue update_issue
    list_notifications answer_notification escalate_question withdraw_question
    list_knowledge read_knowledge semantic_search
    web_search web_fetch
    query_logs get_trace slow_spans error_summary
  )

  # Models, most preferred first; the first whose provider the account holds a
  # key for wins (story 983, `Agents.Defaults`).
  #
  # QA leads with the cheapest thing that can follow instructions, because it
  # runs constantly and reads more than it reasons. Main leads with the
  # strongest, because it is the one explaining the project to somebody who
  # cannot read the code.
  @strong [
    {"anthropic", "claude-sonnet-5"},
    {"openai-codex", "gpt-5.4"},
    {"zai", "glm-5.3"}
  ]

  @cheap [
    {"zai", "glm-5.3"},
    {"openai-codex", "gpt-5.4-mini"},
    {"anthropic", "claude-haiku-4-5"}
  ]

  # In role order: `roles/0` is this list's order, and so is every enum built
  # from it.
  @profiles [
    # The project's own agent. `:main` tools are deliberately everything: its
    # job is the whole project, so scoping it is scoping the thing that checks
    # the others.
    %{
      role: :main,
      # Any requirement no role is named on is main's (John, step 4b).
      requirements: [:tagged, :untagged],
      scope: :project,
      story_vantage: :copy,
      home_copy: :main,
      # Findings because it fixes code; a teammate stalling or dying because it
      # is the one who restarts or unsticks it (step 4b). Not widget issues: a
      # new issue reaches the fleet as `issues_triaged` work (criterion 1755).
      wake: [
        :work_offer,
        :nudge,
        :resume,
        :teammate_question,
        :findings,
        :cadence,
        :teammate_stalled,
        :teammate_died
      ],
      # Its own question holds the turn-end nudge: it has nothing else to do.
      # Another role's question blocks only the task it was asked about
      # (0b324cab, story 1080). Its event wakes and check-in still reach it.
      waiting_on: [question_pending: [:turn_end]],
      questions_block?: true,
      # Nobody is above it: its question is a decision it could not make.
      questions_to: :user,
      tools: :all,
      browses?: true,
      # Not held on problems: fixing a broken tree is coding's (John, step 4b).
      holds_problems?: false,
      # Offered only its own work, but may take over any role's by hand to
      # unstick a teammate (John, 2026-10-01).
      claims_any?: true,
      model_preference: @strong
    },
    # Lives on the main copy beside main and designs an epic there before the
    # epic goes to a working copy; never holds a story (John, step 4c).
    %{
      role: :product,
      requirements: [:tagged],
      scope: :epic,
      # Owns all triage, three amigos and story design, so it sees every story
      # wherever it is placed — from the main copy, where it lives (step 4d).
      story_vantage: :project,
      home_copy: :main,
      # Teammates' questions about criteria and spec are routed to it
      # (8c91d5bc, `ask_user_question`'s `about: "criteria"`).
      wake: [:work_offer, :nudge, :resume, :teammate_question],
      # Its own question blocks only the task it was asked about, as coding's
      # and QA's do (story 1080).
      waiting_on: [],
      # A story's red cards are not its own questions: it is the actor that
      # clears them (`questions_answered`), so blocking it on them left the
      # block naming no actor (56cf5697).
      questions_block?: false,
      questions_to: :main,
      tools: @product_tools,
      browses?: false,
      holds_problems?: false,
      claims_any?: false,
      model_preference: @strong
    },
    %{
      role: :coding,
      requirements: [:tagged],
      scope: :story,
      story_vantage: :copy,
      home_copy: :feature,
      # Findings because it fixes code. QA and product do not: a digest that
      # says "call `list_problems`" is a turn with no move for a role that
      # does not carry it.
      wake: [:work_offer, :nudge, :resume, :findings],
      waiting_on: [],
      questions_block?: true,
      questions_to: :main,
      tools: @coding_tools,
      browses?: true,
      holds_problems?: true,
      claims_any?: false,
      model_preference: @strong
    },
    %{
      role: :qa,
      requirements: [:tagged],
      scope: :story,
      story_vantage: :copy,
      home_copy: :feature,
      wake: [:work_offer, :nudge, :resume],
      waiting_on: [],
      questions_block?: true,
      questions_to: :main,
      tools: @qa_tools,
      browses?: true,
      holds_problems?: false,
      claims_any?: false,
      model_preference: @cheap
    }
  ]

  # Maps at compile time: a module cannot build its own struct in its body.
  @by_role Map.new(@profiles, &{&1.role, &1})
  @roles Enum.map(@profiles, & &1.role)

  @doc "Every role, in order."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc "Every profile, in role order."
  @spec all() :: [t()]
  def all, do: Enum.map(@roles, &get/1)

  @doc "The profile for `role` (atom or string), or nil for a role nobody defined."
  @spec get(atom() | String.t() | nil) :: t() | nil
  def get(role) when is_atom(role), do: build(Map.get(@by_role, role))

  def get(role) when is_binary(role),
    do: Enum.find(@roles, &(Atom.to_string(&1) == role)) |> then(&(&1 && get(&1)))

  defp build(nil), do: nil
  defp build(fields), do: struct!(__MODULE__, fields)

  @doc "The roles whose `field` is true."
  @spec roles_where(atom()) :: [role()]
  def roles_where(field), do: for(profile <- all(), Map.fetch!(profile, field), do: profile.role)

  @doc """
  The roles that staff a working copy when nobody says otherwise: every role
  whose home is a feature copy.
  """
  @spec feature_roles() :: [role()]
  def feature_roles, do: roles_where_home(:feature)

  @doc "The roles whose home copy is `home`."
  @spec roles_where_home(:main | :feature) :: [role()]
  def roles_where_home(home),
    do: for(profile <- all(), profile.home_copy == home, do: profile.role)

  @doc "What `role` works across; `nil` for anything that is not a role (a session)."
  @spec scope(atom() | String.t() | nil) :: :project | :epic | :story | nil
  def scope(role), do: get_field(role, :scope)

  @doc "Whose stories `role` reads: `:copy` for anything that is not a role."
  @spec story_vantage(atom() | String.t() | nil) :: :copy | :project
  def story_vantage(role), do: get_field(role, :story_vantage) || :copy

  @doc "Whether `role` may start on the project's main checkout."
  @spec lives_on_main_copy?(atom() | String.t() | nil) :: boolean()
  def lives_on_main_copy?(role), do: match?(%{home_copy: :main}, get(role))

  @doc "`:all`, the role's explicit list, or `[]` for a role nobody defined."
  @spec tools(atom() | String.t() | nil) :: :all | [String.t()]
  def tools(role) do
    case get(role) do
      nil -> []
      profile -> profile.tools
    end
  end

  @doc "Whether `name` is a tool `role` may call."
  @spec carries?(atom(), String.t()) :: boolean()
  def carries?(role, name) do
    case tools(role) do
      :all -> true
      list -> name in list
    end
  end

  @doc "The requirement selectors for `role`; `[]` for a role nobody defined."
  @spec requirements(atom() | nil) :: [:tagged | :untagged]
  def requirements(role) do
    case get(role) do
      nil -> []
      profile -> profile.requirements
    end
  end

  @doc "The model preference for `role`; `[]` for a role nobody defined."
  @spec model_preference(atom() | nil) :: [{String.t(), String.t()}]
  def model_preference(role) do
    case get(role) do
      nil -> []
      profile -> profile.model_preference
    end
  end

  @doc """
  Whether problems are this role's to fix. Anything that is not a role atom
  (`nil`: a person or a Claude Code session) is unscoped; a role nobody
  defined holds none.
  """
  @spec holds_problems?(term()) :: boolean()
  def holds_problems?(role) when is_atom(role) and not is_nil(role),
    do: match?(%{holds_problems?: true}, get(role))

  def holds_problems?(_role), do: true

  @doc """
  Whether this role may start a requirement it is not offered. Anything that
  is not a role atom (a person or a Claude Code session) may.
  """
  @spec claims_any?(term()) :: boolean()
  def claims_any?(role) when is_atom(role) and not is_nil(role),
    do: match?(%{claims_any?: true}, get(role))

  def claims_any?(_role), do: true

  @doc """
  Whether an open question on the story blocks this role's story work. `nil`
  and roles nobody defined are blocked, as every role was before 56cf5697.
  """
  @spec questions_block?(term()) :: boolean()
  def questions_block?(role) when is_atom(role) do
    case get(role) do
      nil -> true
      profile -> profile.questions_block?
    end
  end

  def questions_block?(_role), do: true

  @doc "Whether `role` is woken by `event` (an `Agents.Wake` event kind)."
  @spec wakes_on?(atom() | nil, atom()) :: boolean()
  def wakes_on?(role, event), do: event in (get_field(role, :wake) || [])

  @doc "Whether `Agents.Waiting` holds `role` on `wait` along `path`."
  @spec waits_on?(atom() | nil, atom(), atom()) :: boolean()
  def waits_on?(role, wait, path),
    do: path in Keyword.get(get_field(role, :waiting_on) || [], wait, [])

  @doc "Whether this role's machine browser tools are added to its list."
  @spec browses?(atom() | nil) :: boolean()
  def browses?(role), do: get_field(role, :browses?) == true

  @doc "Who `role`'s own questions go to first; a role nobody defined goes to main."
  @spec questions_to(atom() | nil) :: :main | :user
  def questions_to(role), do: get_field(role, :questions_to) || :main

  defp get_field(nil, _field), do: nil

  defp get_field(role, field) do
    case get(role) do
      nil -> nil
      profile -> Map.fetch!(profile, field)
    end
  end
end
