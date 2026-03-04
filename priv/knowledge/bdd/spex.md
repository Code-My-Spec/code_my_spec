# BDD Specifications with Spex + Wallaby

## Sources
- SexySpex hex package: https://hex.pm/packages/sexy_spex
- SexySpex docs: https://hexdocs.pm/sexy_spex
- Wallaby hex package: https://hex.pm/packages/wallaby
- Wallaby docs: https://hexdocs.pm/wallaby/Wallaby.html

---

## Overview

Spex is a BDD framework for Elixir built on ExUnit. It provides a Given-When-Then DSL for writing executable specifications that serve as both acceptance tests and living documentation. Spex files run exclusively via `mix spex`, never `mix test`.

BDD specs use **Wallaby** for all browser interactions — driving a real browser via ChromeDriver to click, fill forms, and assert on visible page content. This replaces `Phoenix.LiveViewTest` for BDD specs.

> For the full Wallaby API reference, see `./wallaby.md`.

| Concept             | Detail                                          |
|---------------------|-------------------------------------------------|
| Framework           | `SexySpex` (hex: `sexy_spex`)                   |
| Browser driver      | `Wallaby` (hex: `wallaby`, `~> 0.30`)           |
| Foundation          | ExUnit with `async: false`                      |
| DSL macros          | `spex`, `scenario`, `given_`, `when_`, `then_`, `and_` |
| File pattern        | `test/spex/**/*_spex.exs`                       |
| Run command         | `mix spex`                                      |
| Boundary module     | `AppSpex` in `test/spex/app_spex.ex`            |
| Shared givens       | `AppSpex.SharedGivens` in `test/support/shared_givens.ex` |

---

## Project Structure

```
test/spex/
├── my_app_spex.ex              # Boundary definition (deps: [MyAppWeb, MyAppTest])
└── {story_id}_{story_slug}/    # One directory per story
    ├── criterion_{id}_{slug}_spex.exs
    └── criterion_{id}_{slug}_spex.exs
```

### Boundary Definition

Every project needs a boundary module that restricts spex files to the web layer:

```elixir
defmodule MyAppSpex do
  @moduledoc """
  Boundary definition for BDD specifications.

  Enforces surface-layer testing — spex files can only depend on the
  Web layer and test support, not context modules directly.
  """

  use Boundary, deps: [MyAppWeb, MyAppTest], exports: []
end
```

> For the full boundary library reference and application-wide hierarchy, see `../boundary.md`.

---

## Spex DSL Reference

### Module Setup

```elixir
defmodule MyAppSpex.UserRegistrationSpex do
  use SexySpex                    # ExUnit.Case (async: false) + DSL import
  use Wallaby.DSL                 # Imports Wallaby.Browser, aliases Query + Element

  import Wallaby.Query            # Query helpers: css, button, text_field, link, etc.
  import_givens MyAppSpex.SharedGivens  # Shared step definitions
end
```

`use SexySpex` expands to:

```elixir
use ExUnit.Case, async: false
import SexySpex.DSL
require Logger
```

`use Wallaby.DSL` imports all `Wallaby.Browser` functions (`visit`, `fill_in`, `click`, `assert_has`, etc.) and aliases `Wallaby.Query` and `Wallaby.Element`.

All standard ExUnit features remain available: `setup_all`, `setup`, `on_exit`, `assert`, `refute`, `assert_raise`.

### Macros

| Macro           | Purpose                  | Args                              |
|-----------------|--------------------------|-----------------------------------|
| `spex/2`        | Define a specification   | `name`, `do: block`               |
| `spex/3`        | Spec with options        | `name`, `opts`, `do: block`       |
| `scenario/2`    | Group steps (no context) | `name`, `do: block`               |
| `scenario/3`    | Group steps with context | `name`, `context`, `do: block`    |
| `given_/2`      | Precondition (no ctx)    | `description`, `do: block`        |
| `given_/3`      | Precondition with ctx    | `description`, `context`, `do: block` |
| `when_/2`       | Action (no context)      | `description`, `do: block`        |
| `when_/3`       | Action with context      | `description`, `context`, `do: block` |
| `then_/2`       | Assertion (no context)   | `description`, `do: block`        |
| `then_/3`       | Assertion with context   | `description`, `context`, `do: block` |
| `and_/2`        | Additional step (no ctx) | `description`, `do: block`        |
| `and_/3`        | Additional step with ctx | `description`, `context`, `do: block` |

### Spex Options

```elixir
spex "user registration",
  description: "Validates the full registration flow",
  tags: [:authentication, :registration] do
  # scenarios here
end
```

| Option          | Type              | Purpose                         |
|-----------------|-------------------|---------------------------------|
| `:description`  | `String.t()`      | Human-readable summary          |
| `:tags`         | `[atom()]`        | Categorization (printed, not filterable) |

---

## Context Flow

Context is an explicit map that threads state between steps. Each step that takes a `context` parameter receives the current context and must return `:ok` or `{:ok, updated_context}`.

### How Context Flows

1. ExUnit's `setup` or `setup_all` provides the initial context (e.g., `%{session: session}`)
2. `scenario "name", context do` initializes the scenario context from ExUnit
3. Each step receives context, returns `:ok` (keep unchanged) or `{:ok, new_context}` (update)
4. The next step receives the updated context

### Context Rules

| Rule                                    | Example                                            |
|-----------------------------------------|----------------------------------------------------|
| Return `{:ok, context}` to update       | `{:ok, Map.put(context, :email, email)}`           |
| Return `:ok` to keep context unchanged  | `:ok` (common in `then_` steps)                    |
| Use `_context` when unused              | `given_ "desc", _context do`                       |
| Omit context when not needed            | `then_ "desc" do assert true end`                  |

**Important:** Returning a bare map will raise `ArgumentError`. Always wrap in `{:ok, map}`.

### Pattern

```elixir
scenario "user registers successfully", context do
  given_ "the registration page is loaded", context do
    context.session
    |> visit("/users/register")

    :ok
  end

  when_ "user submits valid credentials", context do
    context.session
    |> fill_in(text_field("Email"), with: "test@example.com")
    |> fill_in(text_field("Password"), with: "SecurePass123!")
    |> click(button("Create account"))

    :ok
  end

  then_ "user sees welcome message", context do
    context.session
    |> assert_has(css(".alert", text: "Welcome"))

    :ok
  end
end
```

---

## Setup: Wallaby Session in Spex

BDD specs need a Wallaby browser session. Set this up in `setup`:

```elixir
defmodule MyAppSpex.UserRegistrationSpex do
  use SexySpex
  use Wallaby.DSL

  import Wallaby.Query
  import_givens MyAppSpex.SharedGivens

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: true)
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(MyApp.Repo, pid)
    {:ok, session} = Wallaby.start_session(metadata: metadata)

    on_exit(fn ->
      Wallaby.end_session(session)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    {:ok, session: session}
  end
end
```

> **Note:** Spex files use `async: false`, so the sandbox must use `shared: true` mode.

---

## Testing Patterns by Component Type

### LiveView Specs (Surface Layer)

Test what users **see and do** through a real browser via Wallaby. Do not call context functions directly.

```elixir
defmodule MyAppSpex.UserRegistrationSpex do
  use SexySpex
  use Wallaby.DSL

  import Wallaby.Query
  import_givens MyAppSpex.SharedGivens

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: true)
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(MyApp.Repo, pid)
    {:ok, session} = Wallaby.start_session(metadata: metadata)

    on_exit(fn ->
      Wallaby.end_session(session)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    {:ok, session: session}
  end

  spex "User registration",
    description: "Users can register through the registration form",
    tags: [:authentication] do

    scenario "user registers with valid data", context do
      given_ "the registration page is loaded", context do
        context.session |> visit("/users/register")
        :ok
      end

      when_ "user fills in and submits the form", context do
        context.session
        |> fill_in(text_field("Email"), with: "newuser@example.com")
        |> fill_in(text_field("Password"), with: "ValidPassword123!")
        |> click(button("Create account"))

        :ok
      end

      then_ "user sees success confirmation", context do
        context.session
        |> assert_has(css(".alert", text: "registered successfully"))

        :ok
      end
    end

    scenario "user sees validation errors for invalid input", context do
      given_ "the registration page is loaded", context do
        context.session |> visit("/users/register")
        :ok
      end

      when_ "user submits invalid data", context do
        context.session
        |> fill_in(text_field("Email"), with: "not-an-email")
        |> fill_in(text_field("Password"), with: "short")
        |> click(button("Create account"))

        :ok
      end

      then_ "user sees error messages", context do
        context.session
        |> assert_has(css(".error", text: "must have the @ sign"))
        |> assert_has(css(".error", text: "should be at least"))

        :ok
      end
    end
  end
end
```

#### Wallaby Testing Helpers

| Action                     | Code                                                      |
|----------------------------|------------------------------------------------------------|
| Navigate to page           | `session \|> visit("/path")`                               |
| Fill text field             | `session \|> fill_in(text_field("Label"), with: "value")`  |
| Click button               | `session \|> click(button("Text"))`                        |
| Click link                 | `session \|> click(link("Text"))`                          |
| Assert visible text        | `session \|> assert_has(css(".class", text: "expected"))`  |
| Assert element exists      | `session \|> assert_has(css("#element-id"))`               |
| Assert element gone        | `session \|> refute_has(css(".error"))`                    |
| Assert current path        | `assert current_path(session) == "/target"`                |
| Get element text           | `session \|> find(css(".title")) \|> Element.text()`       |
| Check checkbox             | `session \|> set_value(checkbox("Label"), :selected)`      |
| Select dropdown option     | `session \|> click(option("Value"))`                       |
| Accept confirmation dialog | `accept_confirm(session, fn s -> s \|> click(button("Delete")) end)` |
| Take screenshot            | `take_screenshot(session, name: "debug")`                  |

### Controller Specs (Surface Layer)

Controller specs that test JSON APIs or form POST endpoints don't need a browser.
These still use `Phoenix.ConnTest` directly:

```elixir
defmodule MyAppSpex.ResourceApiSpex do
  use SexySpex
  use MyAppWeb.ConnCase

  import_givens MyAppSpex.SharedGivens

  spex "Resource API" do
    scenario "create resource with valid data", context do
      when_ "client submits valid data", context do
        conn = post(context.conn, "/api/resources", %{
          resource: %{name: "Test Resource"}
        })
        {:ok, Map.put(context, :response_conn, conn)}
      end

      then_ "API returns created resource", context do
        assert %{"id" => _, "name" => "Test Resource"} =
          json_response(context.response_conn, 201)
        :ok
      end
    end
  end
end
```

---

## Shared Givens

Shared givens extract duplicated setup code into reusable named steps. They live in `test/support/shared_givens.ex`.

### Definition

```elixir
defmodule MyAppSpex.SharedGivens do
  @moduledoc """
  Shared given steps for BDD specifications.

  Import in spec files with:
      import_givens MyAppSpex.SharedGivens
  """

  use SexySpex.Givens

  # Each shared given sets up state through the UI via Wallaby, not fixtures
  # given_ :user_registered do
  #   {:ok, session} = Wallaby.start_session()
  #   session
  #   |> Wallaby.Browser.visit("/users/register")
  #   |> Wallaby.Browser.fill_in(Wallaby.Query.text_field("Email"),
  #        with: "test#{System.unique_integer()}@example.com")
  #   |> Wallaby.Browser.fill_in(Wallaby.Query.text_field("Password"),
  #        with: "ValidPassword123!")
  #   |> Wallaby.Browser.click(Wallaby.Query.button("Create account"))
  #   :ok
  # end
end
```

### Usage in Specs

```elixir
defmodule MyAppSpex.DashboardSpex do
  use SexySpex
  use Wallaby.DSL

  import Wallaby.Query
  import_givens MyAppSpex.SharedGivens

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: true)
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(MyApp.Repo, pid)
    {:ok, session} = Wallaby.start_session(metadata: metadata)

    on_exit(fn ->
      Wallaby.end_session(session)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    {:ok, session: session}
  end

  spex "Dashboard" do
    scenario "authenticated user sees dashboard", context do
      given_ :user_registered          # atom syntax — references shared given
      given_ "user navigates to dashboard", context do
        context.session |> visit("/dashboard")
        :ok
      end

      then_ "dashboard content is visible", context do
        context.session
        |> assert_has(css("h1", text: "Welcome"))

        :ok
      end
    end
  end
end
```

### When to Use Shared Givens

| Use shared givens for                          | Use inline givens for                     |
|------------------------------------------------|-------------------------------------------|
| Setup duplicated across multiple specs         | One-off, scenario-specific setup          |
| Generic state (user registered, logged in)     | Criterion-specific test data              |
| Commonly needed preconditions                  | Complex context that varies per scenario  |

Shared givens must set up state through the UI (Wallaby browser interactions), not by calling context functions or fixtures directly.

---

## Surface Layer Testing Principles

BDD specs test **user-facing behavior**, not internal implementation. This enforces a strict boundary: specs interact with the application the same way a real user would — through a real browser.

| Principle                              | Correct                                             | Incorrect                               |
|----------------------------------------|-----------------------------------------------------|-----------------------------------------|
| Test what users see                    | `session \|> assert_has(css("h1", text: "Welcome"))` | `assert Users.get!(id).active?`         |
| Set up state through UI               | Fill registration form via Wallaby                  | `Users.create_user(scope, attrs)`       |
| Assert on user feedback                | `session \|> assert_has(css(".alert", text: "saved"))` | `assert {:ok, _} = Things.create(...)` |
| Use web layer dependencies only        | `use Wallaby.DSL`                                   | `alias MyApp.Users`                     |

> The `boundary` library enforces this surface-layer constraint at compile time. See `../boundary.md`.

### Path Conventions

Use plain string paths with Wallaby's `visit`:

```elixir
# Correct
session |> visit("/users/register")

# Avoid — Wallaby doesn't use Phoenix verified routes
session |> visit(~p"/users/register")
```

---

## Running Spex

```bash
# Run all spex files (default pattern: test/spex/**/*_spex.exs)
mix spex

# Run a specific file
mix spex test/spex/123_user_registration/criterion_456_valid_email_spex.exs

# Run with a custom pattern
mix spex --pattern "**/integration_*_spex.exs"

# Verbose output (ExUnit trace mode)
mix spex --verbose

# Manual mode — pause at each step, IEx debugging
mix spex --manual

# Custom timeout (default: 60s)
mix spex --timeout 120000
```

| Flag             | Short | Purpose                                    |
|------------------|-------|--------------------------------------------|
| `--pattern`      |       | Glob pattern for spex files                |
| `--verbose`      | `-v`  | Trace mode with detailed output            |
| `--manual`       | `-m`  | Interactive step-by-step execution         |
| `--timeout`      |       | Test timeout in milliseconds               |
| `--help`         | `-h`  | Show usage information                     |

### Manual Mode

Manual mode pauses before each step and offers:
- **[ENTER]** — continue executing the step
- **[iex]** — drop into a debug shell (evaluate arbitrary Elixir, type `exit` to return)
- **[q]** — quit test execution

---

## ExUnit Integration

Since Spex is built on ExUnit, all standard callbacks and assertions are available.

### Setup Callbacks

```elixir
defmodule MyAppSpex.FeatureSpex do
  use SexySpex
  use Wallaby.DSL

  import Wallaby.Query

  # Setup: create Wallaby session with Ecto sandbox
  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: true)
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(MyApp.Repo, pid)
    {:ok, session} = Wallaby.start_session(metadata: metadata)

    on_exit(fn ->
      Wallaby.end_session(session)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    {:ok, session: session}
  end
end
```

### Assertions

All ExUnit assertions work in any step, alongside Wallaby's `assert_has`/`refute_has`:

```elixir
given_ "data is set up", context do
  context.session |> visit("/things/new")
  :ok
end

then_ "page has expected content", context do
  # Wallaby assertions (auto-retry, handles async)
  context.session
  |> assert_has(css("h1", text: "New Thing"))
  |> assert_has(css("#thing-form"))

  # ExUnit assertions still work
  assert current_path(context.session) == "/things/new"
  :ok
end
```

### Failure Behavior

When an assertion fails in any step:
1. The step raises an `ExUnit.AssertionError`
2. The scenario catches it and reports via `SexySpex.Reporter.scenario_failed/2`
3. The spex catches it and reports via `SexySpex.Reporter.spex_failed/2`
4. The error re-raises with full stacktrace
5. ExUnit marks the test as failed
6. If `screenshot_on_failure: true`, Wallaby captures a screenshot

---

## Output Format

Spex produces structured output with visual markers:

```
🎯 Running Spex: User registration
==================================================
   Validates the full registration flow
   Tags: #authentication #registration

  📋 Scenario: user registers with valid data
    Given: the registration page is loaded
    When: user fills in and submits the form
    Then: user sees success confirmation
  ✅ Scenario passed: user registers with valid data

  📋 Scenario: user sees validation errors for invalid input
    Given: the registration page is loaded
    When: user submits invalid data
    Then: user sees error messages
  ✅ Scenario passed: user sees validation errors for invalid input

✅ Spex completed: User registration
```

---

## Complete Example: CRUD LiveView Spec

```elixir
defmodule MyAppSpex.ThingManagementSpex do
  use SexySpex
  use Wallaby.DSL

  import Wallaby.Query
  import_givens MyAppSpex.SharedGivens

  setup do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: true)
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(MyApp.Repo, pid)
    {:ok, session} = Wallaby.start_session(metadata: metadata)

    on_exit(fn ->
      Wallaby.end_session(session)
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    {:ok, session: session}
  end

  # ConnCase setup provides :conn with authenticated user

  spex "Thing management",
    description: "Users can create, view, edit, and delete things",
    tags: [:things, :crud] do

    scenario "user creates a new thing", context do
      given_ "user navigates to the new thing page", context do
        context.session |> visit("/things/new")
        :ok
      end

      when_ "user submits a valid thing", context do
        context.session
        |> fill_in(text_field("Name"), with: "My Thing")
        |> click(button("Save"))

        :ok
      end

      then_ "user sees the thing was created", context do
        context.session
        |> assert_has(css(".alert", text: "Thing created successfully"))

        :ok
      end
    end

    scenario "user sees validation errors", context do
      given_ "user navigates to the new thing page", context do
        context.session |> visit("/things/new")
        :ok
      end

      when_ "user submits without a name", context do
        context.session
        |> fill_in(text_field("Name"), with: "")
        |> click(button("Save"))

        :ok
      end

      then_ "user sees a validation error", context do
        context.session
        |> assert_has(css(".error", text: "can't be blank"))

        :ok
      end
    end

    scenario "user lists existing things", context do
      given_ "user navigates to the things index", context do
        context.session |> visit("/things")
        :ok
      end

      then_ "user sees the listing page", context do
        context.session
        |> assert_has(css("h1", text: "Listing Things"))

        :ok
      end
    end

    scenario "user deletes a thing", context do
      given_ "a thing exists and user is on the index page", context do
        # Create via UI first (surface layer only)
        context.session
        |> visit("/things/new")
        |> fill_in(text_field("Name"), with: "To Delete")
        |> click(button("Save"))
        |> visit("/things")
        |> assert_has(css("td", text: "To Delete"))

        :ok
      end

      when_ "user clicks delete and confirms", context do
        accept_confirm(context.session, fn session ->
          session |> click(link("Delete"))
        end)

        :ok
      end

      then_ "the thing is removed from the list", context do
        context.session
        |> refute_has(css("td", text: "To Delete"))

        :ok
      end
    end
  end
end
```

---

## Configuration

Application-level config for SexySpex behavior:

```elixir
# config/test.exs
config :sexy_spex,
  manual_mode: false,    # Enable interactive step-by-step execution
  step_delay: 0          # Milliseconds to pause between steps (useful for visual testing)

# Wallaby config (for BDD browser tests)
config :wallaby,
  driver: Wallaby.Chrome,
  otp_app: :my_app,
  screenshot_on_failure: true,
  max_wait_time: 5_000   # ms to wait for elements (default: 3000)
```
