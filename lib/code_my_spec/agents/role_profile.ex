defmodule CodeMySpec.Agents.RoleProfile do
  @moduledoc """
  What each role is, as one data definition per role.

  Every role-conditional site reads its profile here rather than matching on
  the role atom, so reshaping a role is editing one entry.

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
      assigned a story of its epic by claiming its work.
    * `story_vantage` — whose stories its requirements are read on. `:copy`
      reads the stories its checkout can see; `:project` reads every story in
      the project wherever it is placed, each at its placement copy's verdict.
    * `home_copy` — `:main` for the roles that live on the project's main
      checkout, `:feature` for the ones that staff a working copy. Only a
      `:main` role may start on the main copy.
    * `wake` — the `Agents.Wake` event kinds it is woken by, beyond those
      relevant to everyone (a person's message, replies to its own requests):
      `:work_offer` (the graph), `:nudge` (its turn-end review), `:resume`
      (a task it holds with no turn open), `:teammate_question` (questions
      other agents raised that it answers first), `:findings` (analysis
      findings nobody asked it for), `:cadence` (the main agent's check-in
      timer), `:teammate_stalled` / `:teammate_died` (a teammate stalled,
      died or was reaped) and `:provisioning_failed`.
    * `waiting_on` — role-specific waits, each with the `Agents.Waiting`
      paths it holds. `:question_pending` is its own unanswered question.
    * `questions_block?` — whether an open question on its story blocks its
      story work.
    * `questions_to` — who its own questions go to first: `:main` or `:user`.
    * `tools` — `:all`, or the explicit list it may call.
    * `browses?` — whether its machine's browser tools are added to its list.
    * `holds_problems?` — whether a broken tree holds it (it can fix one).
    * `claims_any?` — whether it may start a requirement it is not offered.
    * `model_preference` — providers and models, most preferred first.
  """

  use Boundary, top_level?: true, deps: []

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

  # Reading, and writing what a QA run produces — nothing that edits the story
  # itself: a QA agent that can rewrite a criterion can make a failing run pass.
  #
  # `browser` is a capability, not a tool name (see
  # `McpServers.CodeMode.browser_capability/0`). `call_mcp_server` lets QA test
  # a tool surface as a caller rather than being granted each tool under test.
  # File tools because QA's own requirements are files it writes. The copy's own
  # app (and its preview address) runs the branch under test. `list_problems`
  # without `clear_problems`: QA reads findings, never clears or is held by them.
  # See knowledge/agents/coordination, "Role profiles".
  @qa_tools ~w(
    message_agent
    list_stories get_story list_story_titles show_story_requirements get_story_gherkin
    show_component_requirements show_namespace_hierarchy
    list_requirements show_requirement list_personas get_persona
    list_issues get_issue create_issue accept_issue dismiss_issue resolve_issue update_issue
    list_qa_attempts submit_qa_result submit_issue_qa_result invalidate_qa_attempt
    withdraw_question ask_question tap_out cancel_task
    call_mcp_server get_local_app_token
    ensure_app_running restart_app stop_app share_copy_app unshare_copy_app
    list_knowledge read_knowledge semantic_search
    read_project_file write_project_file
    list_tasks list_notifications
    check_answer list_user_questions tool_docs search_answers
    list_problems get_analysis_output
    start_analysis
    web_search web_fetch
    browser
    query_logs get_trace slow_spans error_summary
  )

  # Writing code against a spec, and reading everything that says what the spec
  # is. No issue triage and no QA submission (grading its own work).
  # `resolve_issue` because `issues_resolved` is coding's (QA re-tests it);
  # `create_issue` so a found problem is written down, not fixed on the spot.
  # `promote` is a direct (`LocalServer`) tool, not a scriptable one.
  # `install_credo_checks` because `spex_boundary_ready` is coding's.
  # `list_working_copies` is read-only; making and looping copies is main's.
  # See knowledge/agents/coordination, "Role profiles".
  @coding_tools ~w(
    message_agent
    list_stories get_story list_story_titles show_story_requirements get_story_gherkin
    show_component_requirements show_namespace_hierarchy get_component
    create_component update_component validate_dependency_graph set_story_component
    add_dependency remove_dependency
    list_requirements show_requirement
    list_working_copies
    list_rules list_questions withdraw_question ask_question tap_out cancel_task
    check_answer list_user_questions tool_docs
    list_issues get_issue create_issue resolve_issue update_issue submit_story_issue
    list_knowledge read_knowledge semantic_search
    read_project_file write_project_file
    list_tasks clear_problems list_problems get_analysis_output
    install_credo_checks
    web_search web_fetch
    browser
    promote
    ensure_app_running restart_app stop_app
    query_logs get_trace slow_spans error_summary
  )

  # Shaping what gets built, and never building it: stories, criteria, rules,
  # personas, epics, components and their edges. Triage is shaping
  # (`accept_issue`, `dismiss_issue`); declaring an issue fixed (`resolve_issue`)
  # is coding's. No staffing: that is main's.
  @product_tools ~w(
    get_project_onboarding update_project_onboarding
    list_stories get_story list_story_titles create_story update_story retire_story restore_story
    add_criterion retire_criterion restore_criterion get_criterion move_criterion
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
    validate_dependency_graph execute_proposal show_namespace_hierarchy get_component
    list_issues get_issue create_issue triage_issues accept_issue dismiss_issue update_issue
    list_notifications answer_notification escalate_question withdraw_question search_answers
    check_answer list_user_questions tool_docs
    list_knowledge read_knowledge semantic_search
    web_search web_fetch
    query_logs get_trace slow_spans error_summary
  )

  # Models, most preferred first; the first connected provider wins.
  # Main/product handle broad judgment, coding balances capability and cost,
  # and QA runs focused, repeatable checks. Keep provider-specific defaults
  # here so the launcher and the onboarding form resolve the same choices.
  @strong [
    {"anthropic", "claude-sonnet-5"},
    {"openai-codex", "gpt-6-astra"},
    {"zai", "glm-5.3"},
    {"deepinfra", "deepseek-ai/DeepSeek-V3.1"},
    {"claude-code", "claude-opus-5-5"}
  ]

  @coding [
    {"anthropic", "claude-sonnet-5"},
    {"openai-codex", "gpt-6.1-sol"},
    {"zai", "glm-5.3"},
    {"deepinfra", "deepseek-ai/DeepSeek-V3.1"},
    {"claude-code", "claude-sonnet-5"}
  ]

  @cheap [
    {"zai", "glm-5.3"},
    {"openai-codex", "gpt-6-luna"},
    {"anthropic", "claude-haiku-4-5"},
    {"deepinfra", "deepseek-ai/DeepSeek-V3.1"},
    {"claude-code", "claude-sonnet-5"}
  ]

  # In role order: `roles/0` is this list's order, and so is every enum built
  # from it.
  @profiles [
    # The project's own agent. Tools are everything: it checks the others.
    %{
      role: :main,
      # Any requirement no role is named on is main's.
      requirements: [:tagged, :untagged],
      scope: :project,
      story_vantage: :copy,
      home_copy: :main,
      # A teammate stalling or dying because it is the one who restarts or
      # unsticks it. Not widget issues: a new issue reaches the fleet as
      # `issues_triaged` work.
      wake: [
        :work_offer,
        :nudge,
        :resume,
        :teammate_question,
        :findings,
        :cadence,
        :teammate_stalled,
        :teammate_died,
        :provisioning_failed
      ],
      # Its own question holds the turn-end nudge: it has nothing else to do.
      # Another role's question blocks only the task it was asked about. Its
      # event wakes and check-in still reach it.
      waiting_on: [question_pending: [:turn_end]],
      questions_block?: true,
      # Nobody is above it: its question is a decision it could not make.
      questions_to: :user,
      tools: :all,
      browses?: true,
      # Not held on problems: fixing a broken tree is coding's.
      holds_problems?: false,
      # Offered only its own work, but may take over any role's by hand to
      # unstick a teammate.
      claims_any?: true,
      model_preference: @strong
    },
    # Lives on the main copy beside main and designs an epic there before the
    # epic goes to a working copy; never holds a story.
    %{
      role: :product,
      requirements: [:tagged],
      scope: :epic,
      # Owns all triage, three amigos and story design, so it sees every story
      # wherever it is placed — from the main copy, where it lives.
      story_vantage: :project,
      home_copy: :main,
      # Teammates' questions about criteria and spec are routed to it
      # (`ask_question`'s `about: "criteria"`).
      wake: [:work_offer, :nudge, :resume, :teammate_question],
      # Its own question blocks only the task it was asked about, as coding's
      # and QA's do.
      waiting_on: [],
      # A story's red cards are not its own questions: it is the actor that
      # clears them (`questions_answered`), so blocking it on them left the
      # block naming no actor.
      questions_block?: false,
      # Nobody is above it either: a question main could settle is the kind
      # product would have answered itself already, and anything left is the
      # user's call same as main's own.
      questions_to: :user,
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
      model_preference: @coding
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
  and roles nobody defined are blocked.
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
