# List available recipes
default:
    @just --list

# Run the web app (Postgres, port 4000)
server:
    iex -S mix phx.server

# Run as CLI with SQLite
cli *args:
    MIX_ENV=dev_cli iex -S mix run --no-halt {{args}}

# Run tests
test *args:
    mix test {{args}}

# Run a specific test file/line
test-file file:
    mix test {{file}} --trace

# Setup: deps + db
setup:
    mix deps.get && mix ecto.setup

# Reset the dev database
reset-db:
    mix ecto.reset

# Compile with warnings as errors
check:
    mix compile --warnings-as-errors
