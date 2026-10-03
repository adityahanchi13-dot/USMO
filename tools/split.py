"""Split stryker.lua into several Server Addon parts that each fit the ~16K paste limit.

Part 1 hosts a shared table S (signalReceived). Every later part waits until the part before it
has finished loading (signalAsync), imports the top-level locals it uses from S, and exports the
ones later parts need. Code is moved verbatim; only import/export lines are added.
"""
import re, sys, os

SRC, OUTDIR, BUDGET = sys.argv[1], sys.argv[2], int(sys.argv[3])
SIGNAL = "StrykerShared13"
WIDTH = 130
KEYWORDS = set("and break do else elseif end false for function if in local nil not or repeat return then true until while".split())

text = open(SRC).read()


def strip_comment(line):
    q, i = None, 0
    while i < len(line):
        c = line[i]
        if q:
            if c == '\\':
                i += 2
                continue
            if c == q:
                q = None
        elif c in '"\'':
            q = c
        elif line.startswith('--', i):
            return line[:i].rstrip()
        i += 1
    return line.rstrip()


def code_without_strings(s):
    return re.sub(r'"(\\.|[^"\\])*"|\'(\\.|[^\'\\])*\'', '""', s)


# 1. top-level statements: start at column 0 (not end / } / ) / comment)
lines = [strip_comment(l) for l in text.split('\n')]
stmts, cur = [], None
for l in lines:
    if not l.strip():
        continue
    starts = l[0] != ' ' and not re.match(r'^(end|\}|\))', l)
    if starts:
        if cur:
            stmts.append(cur)
        cur = [l]
    else:
        cur.append(l)
if cur:
    stmts.append(cur)

# 2. names each statement defines
def defined(stmt):
    head = stmt[0]
    m = re.match(r'^local function ([A-Za-z_][A-Za-z0-9_]*)', head)
    if m:
        return [m.group(1)]
    m = re.match(r'^local ([A-Za-z_][A-Za-z0-9_, ]*?)\s*=', head)
    if m:
        return [n.strip() for n in m.group(1).split(',')]
    return []

defs = [defined(s) for s in stmts]
toplevel = {}
for i, ns in enumerate(defs):
    for n in ns:
        assert n not in toplevel, "defined twice: " + n
        toplevel[n] = i

def used(stmt_lines):
    code = code_without_strings('\n'.join(stmt_lines))
    names = set()
    for m in re.finditer(r'(?<![\w.:])([A-Za-z_][A-Za-z0-9_]*)', code):
        n = m.group(1)
        if n not in KEYWORDS and n in toplevel:
            names.add(n)
    return names

uses = [used(s) for s in stmts]

# 3. a top-level scalar that is reassigned after its definition must stay in one part
reassigned = {}
for i, s in enumerate(stmts):
    code = code_without_strings('\n'.join(s))
    for n in toplevel:
        if toplevel[n] != i and re.search(r'(?<![\w.:])' + n + r'\s*=(?!=)', code):
            reassigned.setdefault(n, set()).add(i)


def pack(code_lines):
    out, buf, ind = [], None, ''
    for l in code_lines:
        indent = re.match(r'\s*', l).group(0)
        body = l.strip()
        if buf is None:
            buf, ind = body, ''
        elif len(buf) + 1 + len(body) <= WIDTH:
            buf += ' ' + body
        else:
            out.append(buf)
            buf = body
    if buf is not None:
        out.append(buf)
    return out


def chunked_assign(names, fmt):
    # "local a, b = S.a, S.b" / "S.a, S.b = a, b" in groups so lines stay short
    names = sorted(names)
    out = []
    for i in range(0, len(names), 8):
        g = names[i:i + 8]
        out.append(fmt(g))
    return out


def build_part(k, total, idxs, imports, exports):
    head = [
        "-- Stryker rev 13, PART %d of %d. Paste each part as its own Server Addon and run them in order 1 to %d." % (k, total, total),
    ]
    if k == 1:
        head += [
            "-- Commands: :spawn stryker, :stryker driver|commander|board, :fire, :vehicles, :cleanup vehicles",
            "local S = { ready = {} } signalReceived(\"%s\", function() return S end)" % SIGNAL,
        ]
    else:
        head += [
            "local S = nil for _ = 1, 240 do local ok, r = pcall(signalAsync, \"%s\")" % SIGNAL,
            "if ok and type(r) == \"table\" and r.ready and r.ready[%d] then S = r break end task.wait(0.5) end" % (k - 1),
            "if not S then print(\"[Stryker] part %d: part %d is not running. Run parts 1 to %d in order.\") return end" % (k, k - 1, total),
        ]
        head += chunked_assign(imports, lambda g: "local " + ", ".join(g) + " = " + ", ".join("S." + n for n in g))
    body = []
    for i in idxs:
        body += stmts[i]
    tail = chunked_assign(exports, lambda g: ", ".join("S." + n for n in g) + " = " + ", ".join(g))
    tail.append("S.ready[%d] = true print(\"[Stryker] part %d of %d loaded\")" % (k, k, total))
    return '\n'.join(head + pack(body) + tail) + '\n'


def cost(s):
    # characters as the paste box counts them (line breaks as two characters)
    return len(s) + s.count('\n')


# 4. greedy split: add statements while the finished part stays under budget
def plan():
    parts, cur = [], []
    for i in range(len(stmts)):
        trial = cur + [i]
        if cur and cost(render(trial, parts)) > BUDGET:
            parts.append(cur)
            cur = [i]
        else:
            cur = trial
    parts.append(cur)
    return parts


def imports_for(idxs):
    mine = set(n for i in idxs for n in defs[i])
    need = set()
    for i in idxs:
        need |= uses[i]
    return need - mine


def render(idxs, done_parts, total=9, exports=None):
    k = len(done_parts) + 1
    imp = imports_for(idxs) if k > 1 else set()
    exp = exports if exports is not None else set(n for i in idxs for n in defs[i])  # worst case for sizing
    return build_part(k, total, idxs, imp, exp)


parts = plan()
total = len(parts)
os.makedirs(OUTDIR, exist_ok=True)
owner = {}
for p, idxs in enumerate(parts):
    for i in idxs:
        owner[i] = p
for n, where in reassigned.items():
    homes = {owner[toplevel[n]]} | {owner[i] for i in where}
    if len(homes) != 1: print("CHECK reassigned across parts:", n)
results = []
for p, idxs in enumerate(parts):
    later_need = set()
    for q in range(p + 1, total):
        later_need |= imports_for(parts[q])
    mine = set(n for i in idxs for n in defs[i])
    exp = mine & later_need
    imp = imports_for(idxs) if p > 0 else set()
    src = build_part(p + 1, total, idxs, imp, exp)
    path = os.path.join(OUTDIR, "stryker_part%d.txt" % (p + 1))
    open(path, 'w').write(src)
    results.append((path, cost(src), len(src), src.count('\n'), len(imp), len(exp)))
for r in results:
    print("%s: %d paste chars (%d chars, %d lines), imports %d, exports %d" % r)
