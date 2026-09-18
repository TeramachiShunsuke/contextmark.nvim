"""Mutation check: revert one fix at a time and report which tests catch it.

Each mutation gets its own fresh copy under $TMPDIR and nothing is ever deleted,
so this never needs a destructive command.
"""

import os
import subprocess
import sys
import tempfile

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = os.environ.get("TMPDIR", "/tmp").rstrip("/")

MUTATIONS = [
    # --- the sync guard and what it protects
    (
        "sync freeze off",
        "lua/contextmark/render.lua",
        "        if frozen then\n",
        "        if false then\n",
    ),
    (
        "identity verdict ignored",
        "lua/contextmark/render.lua",
        'local replaced = verdict == "replaced"',
        "local replaced = false",
    ),
    (
        "sync verdict ignored",
        "lua/contextmark/render.lua",
        'frozen = file_verdict(bufnr, root, relative, lines) == "replaced"',
        "frozen = false",
    ),
    (
        "degenerate-range guard off",
        "lua/contextmark/render.lua",
        "local degenerate = is_degenerate(lines, first, last, first_col, last_col)",
        "local degenerate = false",
    ),
    (
        "unresolved notes recaptured again",
        "lua/contextmark/render.lua",
        "elseif degenerate or util.is_warning_status(stored.status) then",
        "elseif degenerate then",
    ),
    (
        "live tracking discarded on re-render",
        "lua/contextmark/render.lua",
        "local tracked = not replaced and live[comment.id]",
        "local tracked = false",
    ),
    (
        "replaced note placed on the impostor's match",
        "lua/contextmark/render.lua",
        "        start_line = math.max(1, math.min(comment.anchor.start_line, count))",
        "        do return end",
    ),
    (
        "pushed extmark end not trimmed",
        "lua/contextmark/render.lua",
        "if end_line > start_line and end_col == 0 and span and end_line - start_line > span then",
        "if false then",
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
        "identity small-sample rule bypassed",
        "lua/contextmark/identity.lua",
        "  if total < ratio_floor then",
        "  if false then",
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
        "  if util.is_warning_status(stored.status) then",
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
        "adoption by root membership off",
        "lua/contextmark/init.lua",
        "if there:sub(1, #prefix) == prefix and util.project_root(there) == root then",
        "if false then",
    ),
    (
        "store merge on save off",
        "lua/contextmark/store.lua",
        "  local stamp = stamp_of(path)\n  if not same_stamp(stamps[root], stamp) then",
        "  local stamp = stamp_of(path)\n  if false then",
    ),
    (
        "stale cache never refreshed",
        "lua/contextmark/store.lua",
        "if cached and same_stamp(stamps[root], stamp) then",
        "if cached then",
    ),
    (
        "merge lets ours win for untouched notes",
        "lua/contextmark/store.lua",
        "if original == nil or not vim.deep_equal(original, comment) then",
        "if true then",
    ),
    (
        "save overwrites a sidecar that became unreadable",
        "lua/contextmark/store.lua",
        '    elseif reason ~= "absent" then\n      unreadable[root] = reason',
        '    elseif false then\n      unreadable[root] = reason',
    ),
    (
        "legacy sidecars never retired",
        "lua/contextmark/store.lua",
        "  if retiring[root] then",
        "  if false then",
    ),
    (
        "unopenable sidecar read as absent",
        "lua/contextmark/store.lua",
        "    if vim.uv.fs_stat(path) then\n      return nil, (\"unreadable: %s\")",
        "    if false then\n      return nil, (\"unreadable: %s\")",
    ),
    (
        "moved-project adoption allows escaping keys",
        "lua/contextmark/init.lua",
        "util.relative_path(here, root) == relative and relative",
        "relative",
    ),
    (
        "import indexes a missing id",
        "lua/contextmark/store.lua",
        "the source sidecar keeps it.\n    if comment.id ~= nil and not known[comment.id] then",
        "the source sidecar keeps it.\n    if not known[comment.id] then",
    ),
    (
        "prompt keeps stored lines for an empty file",
        "lua/contextmark/prompt.lua",
        "  if #lines == 0 then\n    return 1, 1\n  end",
        "  if #lines == 0 then\n    return start_line, end_line\n  end",
    ),
    (
        "sidecar without a comments list read as empty",
        "lua/contextmark/store.lua",
        "  if type(decoded.comments) ~= \"table\" then\n    return nil, \"unreadable: no comments list\"\n  end",
        "  if false then\n    return nil, \"unreadable: no comments list\"\n  end\n  decoded.comments = type(decoded.comments) == \"table\" and decoded.comments or {}",
    ),
    (
        "failed re-key marked done",
        "lua/contextmark/init.lua",
        "  else\n    canonicalized[root] = true\n    canonicalize_reported[root] = nil\n  end",
        "  end\n  canonicalized[root] = true\n  do\n    canonicalize_reported[root] = nil\n  end",
    ),
    (
        "failed re-key reported on every BufEnter",
        "lua/contextmark/init.lua",
        "    if not canonicalize_reported[root] then",
        "    if true then",
    ),
    (
        "by-name adoption allows escaping keys",
        "lua/contextmark/init.lua",
        "        -- Same containment as the moved-project branch: \"../x\" must not match.\n        and util.relative_path(here, root) == relative\n",
        "",
    ),
    (
        "reanchor callback accepts an edited buffer",
        "lua/contextmark/init.lua",
        "    -- An asynchronous picker leaves the buffer editable while it is open.\n    if vim.bo[bufnr].modified then",
        "    -- An asynchronous picker leaves the buffer editable while it is open.\n    if false then",
    ),
    (
        "baseline taken when a note fails to resolve this render",
        "lua/contextmark/render.lua",
        "    if util.is_warning_status(status) then\n      suspected = true\n    end",
        "",
    ),
    (
        "path normalization expands $VAR",
        "lua/contextmark/util.lua",
        "  return vim.fs.normalize(path, { expand_env = false })",
        "  return vim.fs.normalize(path)",
    ),
    (
        "move arguments run through expand()",
        "lua/contextmark/init.lua",
        "  local expanded = value\n",
        "  local expanded = vim.fn.expand(value)\n",
    ),
    (
        "adoption joins keys through symlinks",
        "lua/contextmark/init.lua",
        "    local here = util.literal_absolute_path(root, relative)",
        "    local here = util.absolute_path(root, relative)",
    ),
    (
        "late edit replaces the whole note",
        "lua/contextmark/store.lua",
        "      current.body = comment.body\n      current.updated_at = comment.updated_at",
        "      state.comments[_] = comment",
    ),
    (
        "stale lock unlinked by name without the breaker",
        "lua/contextmark/store.lua",
        "local function clear_stale_lock(lock, seen)\n",
        "local function clear_stale_lock(lock, seen)\n  do\n    vim.uv.fs_unlink(lock)\n    return true\n  end\n",
    ),
    (
        "stale lock judged by inode alone",
        "lua/contextmark/store.lua",
        "    and current.mtime.sec == seen.mtime.sec\n    and current.mtime.nsec == seen.mtime.nsec\n    and is_stale(current, lock)\n",
        "\n",
    ),
    (
        "dead breaker never cleared",
        "lua/contextmark/store.lua",
        "    if is_stale(vim.uv.fs_stat(breaker)) then",
        "    if false then",
    ),
    (
        "live lock owner ignored",
        "lua/contextmark/store.lua",
        "    and not (path and owner_is_alive(path))\n",
        "\n",
    ),
    (
        "live lock owner must return dead on ESRCH only",
        "lua/contextmark/store.lua",
        '  return not tostring(result or ""):match("ESRCH")\n',
        "  return false\n",
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
        "  local lock, lock_error = acquire_lock(path)\n  if not lock then",
        "  local lock = path .. \".lock\"\n  if false then",
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
        '              and identity.compare(entry.stored, lines) == "same"',
        "              and true",
    ),
    (
        "move destination not mapped into the root",
        "lua/contextmark/init.lua",
        "  return util.relative_path(util.literal_absolute_path(root, expanded), root)",
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
        "corrupt sidecar treated as empty",
        "lua/contextmark/store.lua",
        "  if unreadable[root] then",
        "  if false then",
    ),
    (
        "unreadable reason discarded on read",
        "lua/contextmark/store.lua",
        '    unreadable[root] = reason ~= "absent" and reason or nil',
        "    unreadable[root] = nil",
    ),
    (
        "damaged anchor not repaired",
        "lua/contextmark/store.lua",
        '    if type(comment.anchor) ~= "table" then\n      comment.anchor = { start_line = 1, end_line = 1, status = "orphaned" }\n    end',
        "",
    ),
    (
        "adoption by name allows live repositories",
        "lua/contextmark/init.lua",
        "local by_name = not entry.missing and not has_repository(recorded)",
        "local by_name = not entry.missing",
    ),
    (
        "adoption by name off",
        "lua/contextmark/init.lua",
        "      elseif\n        by_name\n        and not vim.uv.fs_stat(there)",
        "      elseif\n        false\n        and not vim.uv.fs_stat(there)",
    ),
    (
        "moved-project adoption off",
        "lua/contextmark/init.lua",
        "mapped = vim.uv.fs_stat(here) and util.relative_path(here, root) == relative and relative\n        or false",
        "mapped = false",
    ),
    (
        "symlinked keys not canonicalized",
        "lua/contextmark/init.lua",
        "  if not root or canonicalized[root] then",
        "  if true then",
    ),
    (
        "even sampling replaced by a stepped walk",
        "lua/contextmark/identity.lua",
        "  for step = 1, taken do\n    local index = 1 + math.floor((step - 1) * (#body - 1) / (taken - 1) + 0.5)\n    sample[#sample + 1] = body[index]\n  end",
        "  local stride = math.max(1, math.floor(#body / sample_size))\n  for index = 1, #body, stride do\n    sample[#sample + 1] = body[index]\n    if #sample >= taken then\n      break\n    end\n  end",
    ),
    (
        "tiny samples decide again",
        "lua/contextmark/identity.lua",
        '  if total < ratio_floor then\n    return "unknown", current\n  end',
        "",
    ),
    (
        "replaced coordinates written back",
        "lua/contextmark/render.lua",
        "      if\n        not replaced\n        and not tracked\n        and (",
        "      if\n        not tracked\n        and (",
    ),
    (
        "unsaved draft becomes the baseline",
        "lua/contextmark/render.lua",
        "if fingerprint and not replaced and not undecided and not vim.bo[bufnr].modified then",
        "if fingerprint and not replaced then",
    ),
    (
        "prompt line numbers not clamped",
        "lua/contextmark/prompt.lua",
        "  local first = math.max(1, math.min(start_line, #lines))\n  return first, math.max(first, math.min(end_line, #lines))",
        "  return start_line, end_line",
    ),
    (
        "save ignores a failed write",
        "lua/contextmark/store.lua",
        "  if not written or not closed then",
        "  if false then",
    ),
    (
        "rename takes over a destination that has notes",
        "lua/contextmark/init.lua",
        "  if #store.list(root, relative) > 0 or store.fingerprint(root, relative) then",
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
    failed = [line[len("not ok - ") :] for line in output.splitlines() if line.startswith("not ok")]
    return failed, result.returncode


baseline, code = run(SRC)
print("baseline: %d failing, rc=%s" % (len(baseline), code))
for entry in baseline:
    print("    ! %s" % entry[:160])
print()
# Every mutation is judged by whether some test fails. On a red baseline every
# one of them would read as "caught", so the run proves nothing.
if baseline or code != 0:
    print("baseline is not green; fix the suite before checking mutations")
    sys.exit(1)

# Optional substring filter, so one suspicious mutation can be re-run alone.
only = sys.argv[1] if len(sys.argv) > 1 else None

survived, skipped = [], []
for index, (name, relative, old, new) in enumerate(MUTATIONS):
    if only and only not in name:
        continue
    # A fresh directory every time: copying into a leftover one (a reused PID)
    # nests lua/ inside lua/ and silently tests the stale copy instead.
    work = tempfile.mkdtemp(prefix="mut-%02d-" % index, dir=TMP)
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
        print("%-40s caught by %d:" % (name, len(failed)))
        for entry in failed:
            print("    - %s" % entry[:160])
    else:
        print("%-40s SURVIVED (rc=%s)" % (name, code))
        survived.append(name)

print()
print("survived: %s" % (", ".join(survived) if survived else "none"))
print("skipped:  %s" % (", ".join(skipped) if skipped else "none"))
