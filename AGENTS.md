# AGENTS.md

Durable, project-intrinsic knowledge (curated by `/scribe`). Non-obvious facts that change future actions — not task notes.

## Maintaining this file

Keep only knowledge useful to almost every future agent session in this project.
Don't repeat what the code already shows — point to the file, function, or command instead.
Prefer rewriting or pruning an existing entry over adding a new one; skip trivial tasks that taught nothing durable.
Keep each entry to one line, action first.

- Inside a ParsableCommand, call Foundation.exit(code) — bare exit() resolves to ArgumentParser's exit(withError:) and won't compile with an Int32.
- For 'NAME... -- cmd' parsing use one @Argument(parsing: .captureForPassthrough) and split on '--' yourself — .remaining eats the '--' terminator and .upToNextOption doesn't exist in swift-argument-parser.
