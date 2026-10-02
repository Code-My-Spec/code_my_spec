import Config

# Fragment, not an env: what every harness build shares. Imported first by
# dev_cli, prod_cli, cli_demo and dev_sprite, so the env file overrides it.

config :code_my_spec, stories_implementation: CodeMySpec.Stories.StoriesRepository
config :code_my_spec, personas_implementation: CodeMySpec.Personas.PersonasRepository
config :code_my_spec, bdd_rules_implementation: CodeMySpec.BddRules.BddRulesRepository
config :code_my_spec, questions_implementation: CodeMySpec.Questions.QuestionsRepository

config :code_my_spec,
  acceptance_criteria_implementation: CodeMySpec.AcceptanceCriteria.AcceptanceCriteriaRepository

# The harness serves its own endpoint; the main web endpoint stays off.
config :code_my_spec, CodeMySpecWeb.Endpoint, server: false

# Local-first: SQLite. dev_sprite overrides it for Postgres. No embeddings
# backend: search lives on the server.
config :code_my_spec, adapter: Ecto.Adapters.SQLite3

# PaperTrail strict_mode uses Postgres sequences — SQLite doesn't have them.
# Versions are still recorded but `first_version_id` / `current_version_id`
# columns stay nil.
config :paper_trail, strict_mode: false
