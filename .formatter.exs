[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"],
  # The spex DSL reads as prose — `given_ :synced_context_component`, not
  # `given_(:synced_context_component)`. sexy_spex exports no formatter config,
  # so without this every `mix format` rewrites the whole spex tree and someone
  # reverts it by hand afterwards.
  locals_without_parens: [
    spex: 2,
    scenario: 2,
    given_: 1,
    given_: 2,
    given_: 3,
    when_: 1,
    when_: 2,
    when_: 3,
    then_: 1,
    then_: 2,
    then_: 3,
    register_given: 2
  ]
]
