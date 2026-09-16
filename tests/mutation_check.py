"""Mutation check: revert one fix at a time and report which tests catch it.

Each mutation gets its own fresh copy under $TMPDIR and nothing is ever deleted,
so this never needs a destructive command.
"""

import os
import subprocess

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = os.environ.get("TMPDIR", "/tmp").rstrip("/")

MUTATIONS = [
    # --- the sync guard and what it protects
    (
        "sync guard off",
        "lua/contextmark/render.lua",
        "if frozen or degenerate then",
        "if false then",
    ),
    (
        "identity verdict ignored",
        "lua/contextmark/render.lua",
        'local replaced = verdict == "replaced"',
        "local replaced = false",
    ),
    (
        "sync freeze off",
        "lua/contextmark/render.lua",
        'frozen = identity.compare(store.fingerprint(root, relative), lines) == "replaced"',
        "frozen = false",
    ),
    (
        "degenerate-range guard off",
        "lua/contextmark/render.lua",
        "local degenerate = is_degenerate(lines, first, last, first_col, last_col)",
        "local degenerate = false",
    ),
    (
        "stale notes frozen again",
        "lua/contextmark/render.lua",
        "if frozen or degenerate then",
        "if frozen or degenerate or util.is_warning_status(stored.status) then",
    ),
    (
        "orphaned exception off",
        "lua/contextmark/render.lua",
        'return status == "orphaned" and status or "mismatch"',
        'return "mismatch"',
    ),
    (
        "sync clamp off",
        "lua/contextmark/render.lua",
        "local first = clamp_line(start_line)",
        "local first = start_line",
    ),
    # --- file identity
    (
        "identity reformat tolerance off",
        "lua/contextmark/identity.lua",
        'local trimmed = line:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")',
        "local trimmed = line",
    ),
    (
        "identity distinct-line filter off",
        "lua/contextmark/identity.lua",
        "      if not seen[value] then\n        seen[value] = true\n        result[#result + 1] = value\n      end",
        "      result[#result + 1] = value",
    ),
    (
        "identity threshold made aggressive",
        "lua/contextmark/identity.lua",
        "local survival_denominator = 10",
        "local survival_denominator = 2",
    ),
    (
        "identity blank-line filter off",
        "lua/contextmark/identity.lua",
        '    if line:match("%S") then',
        "    if true then",
    ),
    (
        "identity small-sample rule off",
        "lua/contextmark/identity.lua",
        '    return hits == 0 and "replaced" or "same", current',
        '    return "same", current',
    ),
    # --- path identity
    (
        "leaf realpath off",
        "lua/contextmark/util.lua",
        "  local real = vim.uv.fs_realpath(trimmed)\n  if real then",
        "  local real = nil\n  if real then",
    ),
    (
        "root derived from resolved path",
        "lua/contextmark/util.lua",
        'local root = vim.fs.root(literal, { ".git" })',
        'local root = vim.fs.root(normalize(path), { ".git" })',
    ),
    (
        "literal fallback for escaping links off",
        "lua/contextmark/util.lua",
        "for _, candidate in ipairs({ normalize(path), literal_path(path) }) do",
        "for _, candidate in ipairs({ normalize(path) }) do",
    ),
    (
        "outside-root basename fallback restored",
        "lua/contextmark/util.lua",
        "      if relative then\n        return relative\n      end\n    end\n  end\n  return nil\nend",
        '      if relative then\n        return relative\n      end\n    end\n  end\n  return vim.fn.fnamemodify(path, ":t")\nend',
    ),
    (
        "root join special case off",
        "lua/contextmark/util.lua",
        '  if parent == "/" then\n    return "/" .. leaf\n  end\n',
        "",
    ),
    (
        "buftype gate off",
        "lua/contextmark/util.lua",
        'if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then',
        "if not vim.api.nvim_buf_is_valid(bufnr) then",
    ),
    # --- prompt contract
    (
        "prompt status note off",
        "lua/contextmark/prompt.lua",
        "    local status_note = util.status_note(comment.anchor.status)",
        "    local status_note = nil",
    ),
    (
        "prompt excerpt fallback off",
        "lua/contextmark/prompt.lua",
        "  if util.is_warning_status(comment.anchor.status) then",
        "  if false then",
    ),
    (
        "prompt empty-excerpt fallback off",
        "lua/contextmark/prompt.lua",
        '      if line:match("%S") then\n        return start_line, end_line, excerpt\n      end',
        "      return start_line, end_line, excerpt",
    ),
    (
        "orphaned unreachable again",
        "lua/contextmark/anchor.lua",
        '    return 1, 1, "orphaned", 0, 0',
        '    return nil, nil, "orphaned", nil, nil',
    ),
    # --- storage
    (
        "adoptable relatedness off",
        "lua/contextmark/store.lua",
        "        if missing or related then",
        "        if false then",
    ),
    (
        "store merge on save off",
        "lua/contextmark/store.lua",
        "  if not same_stamp(stamps[root], stamp_of(path)) then\n    local disk = read_state_file(path)",
        "  if false then\n    local disk = read_state_file(path)",
    ),
    (
        "stale cache never refreshed",
        "lua/contextmark/store.lua",
        "if pending[root] or same_stamp(stamps[root], stamp_of(state_path(root))) then",
        "if true then",
    ),
    (
        "deletion tombstones off",
        "lua/contextmark/store.lua",
        "  local tombstones = removed[root]\n  if not tombstones then",
        "  local tombstones = nil\n  if not tombstones then",
    ),
    (
        "save lock off",
        "lua/contextmark/store.lua",
        "  local lock = acquire_lock(path)\n  if not lock then",
        "  local lock = path .. \".lock\"\n  if false then",
    ),
    (
        "pending set before the edit lands",
        "lua/contextmark/store.lua",
        "  local state = load(root)\n  for index, current in ipairs(state.comments) do",
        "  local state = touch(root)\n  for index, current in ipairs(state.comments) do",
    ),
    (
        "rekey overwrites the destination identity",
        "lua/contextmark/store.lua",
        "    if state.files[to] == nil then\n      state.files[to] = state.files[from]\n    end",
        "    state.files[to] = state.files[from]",
    ),
    (
        "rekey same-path guard off",
        "lua/contextmark/store.lua",
        "  if from == to then\n    return true, 0\n  end",
        "",
    ),
    # --- commands and rename following
    (
        "rename follow off",
        "lua/contextmark/init.lua",
        "        settle_rename(event.buf)\n        render.sync(event.buf)",
        "        render.sync(event.buf)",
    ),
    (
        "rename ignores a surviving original",
        "lua/contextmark/init.lua",
        "  if vim.uv.fs_stat(util.absolute_path(before.root, before.file)) then\n    return\n  end",
        "",
    ),
    (
        "rename intent never expires",
        "lua/contextmark/init.lua",
        "  if vim.uv.hrtime() - before.at > rename_ttl_ns then",
        "  if false then",
    ),
    (
        "relocate accepts any file",
        "lua/contextmark/init.lua",
        'if lines and identity.compare(stored, lines) == "same" then',
        "if lines then",
    ),
    (
        "move destination not mapped into the root",
        "lua/contextmark/init.lua",
        "  return util.relative_path(util.absolute_path(root, expanded), root)",
        "  return expanded",
    ),
    (
        "move same-path guard off",
        "lua/contextmark/init.lua",
        "  if from == to then\n    vim.notify(",
        "  if false then\n    vim.notify(",
    ),
    (
        "reanchor accepts an unsaved buffer",
        "lua/contextmark/init.lua",
        "  if vim.bo[bufnr].modified then",
        "  if false then",
    ),
    (
        "cquit argument bug restored",
        "tests/run.lua",
        "vim.cmd.cquit({ count = failures })",
        "vim.cmd.cquit(failures)",
    ),
]

COPY = ["lua", "plugin", "tests", "examples", "docs", "README.md", "CLAUDE.md", "stylua.toml"]


def make_copy(work):
    """Copies only what the suite needs. The real .git holds read-only pack
    files and is not worth duplicating; an empty one keeps root detection the
    same as in the real repository."""
    os.makedirs(os.path.join(work, ".git"), exist_ok=True)
    for item in COPY:
        subprocess.run(
            ["cp", "-a", os.path.join(SRC, item), os.path.join(work, item)], check=True
        )


def run(cwd):
    result = subprocess.run(
        ["nvim", "--headless", "-i", "NONE", "-u", "tests/minimal_init.lua", "-l", "tests/run.lua"],
        cwd=cwd,
        capture_output=True,
        text=True,
    )
    output = result.stdout + result.stderr
    failed = [
        line[len("not ok - ") :].split(":")[0]
        for line in output.splitlines()
        if line.startswith("not ok")
    ]
    return failed, result.returncode


baseline, code = run(SRC)
print("baseline: %d failing, rc=%s" % (len(baseline), code))
print()

survived, skipped = [], []
for index, (name, relative, old, new) in enumerate(MUTATIONS):
    work = "%s/mut-%d-%02d" % (TMP, os.getpid(), index)
    make_copy(work)
    path = os.path.join(work, relative)
    with open(path) as handle:
        text = handle.read()
    if old not in text:
        print("%-40s SKIP  pattern absent in %s" % (name, relative))
        skipped.append(name)
        continue
    with open(path, "w") as handle:
        handle.write(text.replace(old, new, 1))
    failed, code = run(work)
    if failed:
        print("%-40s caught by %d: %s" % (name, len(failed), "; ".join(failed[:2])))
    else:
        print("%-40s SURVIVED (rc=%s)" % (name, code))
        survived.append(name)

print()
print("survived: %s" % (", ".join(survived) if survived else "none"))
print("skipped:  %s" % (", ".join(skipped) if skipped else "none"))
