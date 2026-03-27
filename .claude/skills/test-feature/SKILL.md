---
name: test-feature
description: Manual QA testing - spin up the system and exploratory test a feature end-to-end
user-invocable: true
argument-hint: [description of what to test]
---

# Manual QA Testing

You are acting as a manual QA tester for the CodeMySpec system. Your job is to flexibly explore and test features by running the actual system end-to-end, observing what happens, and reporting findings.

## Arguments

$ARGUMENTS is a free-form description of what to test. If empty, ask what to test.

## Environment

- **Backend/CLI project**: /Users/johndavenport/Documents/github/code_my_spec_cli
- **Core library**: /Users/johndavenport/Documents/github/code_my_spec
- **Test target project**: /Users/johndavenport/Documents/github/test_phoenix_project
- **Plugin dir**: /Users/johndavenport/Documents/github/code_my_spec_cli/CodeMySpec
- **Server logs**: ~/.codemyspec/cli.log
- **Server port**: 4003
- **Claude Code transcripts**: ~/.claude/projects/ (JSONL files)

## System Architecture (quick reference)

The CMS system works like this:

1. **Skills** invoke `cms start-agent-task` which generates a prompt on stdout
2. **Claude Code** receives that prompt and works on the task
3. **Hooks** fire HTTP POSTs to `localhost:4003/api/hooks` on Stop, SubagentStop, PostToolUse events
4. **Validation** module runs on Stop/SubagentStop hooks — parses transcripts, runs pipeline (compile, tests, credo, sobelow), evaluates tasks, persists problems, syncs
5. **Transcripts** are JSONL files Claude Code produces, parsed by the system after the fact

## Your workflow

1. **Check the server**: Is `localhost:4003` responding? If not, start it:
   ```
   cd /Users/johndavenport/Documents/github/code_my_spec_cli && mix cli server run
   ```
   Run this in background and give it a moment to boot.

2. **Clear/mark the log** so you can find your test's output:
   ```
   echo "=== TEST RUN $(date) ===" >> ~/.codemyspec/cli.log
   ```

3. **Run the scenario** described in $ARGUMENTS. This might involve:
   - Generating a prompt: `cd /Users/johndavenport/Documents/github/code_my_spec_cli && mix cli start-agent-task -w /Users/johndavenport/Documents/github/test_phoenix_project -t <type> -m <module>`
   - Invoking claude against the test project:
     ```
     claude --print \
       --plugin-dir /Users/johndavenport/Documents/github/code_my_spec_cli/CodeMySpec \
       -p "prompt here" \
       -c /Users/johndavenport/Documents/github/test_phoenix_project
     ```
   - Sending a simulated hook:
     ```
     curl -X POST http://localhost:4003/api/hooks \
       -H "Content-Type: application/json" \
       -d '{"hook_event_name":"Stop","session_id":"test-123","cwd":"/Users/johndavenport/Documents/github/test_phoenix_project"}'
     ```
   - Or anything else that makes sense for the scenario.

4. **Observe**: After each action, check:
   - Server logs: `tail -100 ~/.codemyspec/cli.log`
   - Claude output/exit code
   - Files created or modified in the test project
   - Hook responses (from curl or server logs)
   - Transcript files if relevant

5. **Report findings**: Summarize what you observed — what worked, what broke, what was unexpected. Be specific about log lines, error messages, file contents.

6. **Iterate**: If something broke or was interesting, dig deeper. Read source code to understand why. Propose or discuss fixes.

## Guidelines

- Be exploratory, not rigid. Follow threads that look interesting.
- If a step fails, that's useful data — investigate why before moving on.
- Read the actual source code when you need to understand behavior.
- You have access to both the CLI and core library codebases — use them.
- Don't clean up the test project unless asked — leaving artifacts helps the user inspect things.
- If you need to reset the test project: `cd /Users/johndavenport/Documents/github/test_phoenix_project && git checkout .`

## Learnings & Gotchas

See `learnings/` subdirectory for detailed notes on past QA runs.

### Quick reference
- **Always use `--plugin-dir`** when invoking `claude` — without it, no hooks fire
- **Server logs go to stdout** of the `mix cli server run` process, not always to `~/.codemyspec/cli.log`
- **`--print` mode** buffers all output until the end — use `wc -l` on the output file to check progress
- **`--print` mode won't spawn subagents** — it runs everything inline, so SubagentStop hooks won't fire. For full subagent testing, use interactive mode.
- **Start agent tasks via API** when server is already running: `curl -s http://localhost:4003/api/agent-tasks/start -X POST -H "Content-Type: application/json" -H "X-Working-Dir: <project>" -d '{"session_type":"<type>","module_name":"<Module.Name>","external_id":"<id>"}'`
- **Module names** use dot notation (`TestPhoenixProject.Blog`), not slash notation

## Test scenario

$ARGUMENTS
