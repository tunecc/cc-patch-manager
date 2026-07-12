#!/bin/bash
#
# Claude Code Ultracode Unlock Patch Script
#
# PURPOSE:
# Unlocks ultracode (/effort ultracode) for models that support max effort
# but not xhigh effort (e.g. opus-4-6, sonnet-4-6).
#
# BACKGROUND:
# Ultracode = xhigh effort + dynamic workflow orchestration.
# Three functions gate it:
#   Gu()  — availability: requires QnH() (xhigh support)
#   Oa()  — effort resolver: degrades xhigh → "high" when QnH returns false
#   za()  — active check: requires Oa() to return exactly "xhigh"
#
# On opus-4-6, QnH() returns false (xhigh unsupported), so:
#   1. Gu() blocks /effort ultracode from appearing
#   2. Even if forced, Oa() degrades xhigh → "high" (skipping max)
#   3. za() sees "high" ≠ "xhigh" → ultracode reminders never injected
#
# FIX STRATEGY (3 patches, preserves all degradation logic):
#
# Patch 1 — Gu(): QnH(H) → QnH(H) || kj6(H)
#   Accept max-capable models for ultracode availability.
#
# Patch 2 — Oa(): xhigh degradation return "high" → kj6(H) ? "max" : "high"
#   When xhigh is unsupported, fall to max instead of high (if model supports max).
#   Degradation chain preserved: xhigh → max → (if max unsupported) → high.
#
# Patch 3 — za(): === "xhigh" → === "xhigh" || ... === "max"
#   Accept max as valid ultracode effort level in active-status check.
#
# DETECTION STRATEGY (AST-based, name-agnostic):
#   QnH: FunctionDeclaration(1 param) containing Literal "xhigh_effort"
#   kj6: FunctionDeclaration(1 param) containing Literal "max_effort"
#   Gu:  FunctionDeclaration(1 param) calling QnH with void 0 check
#   Oa:  FunctionDeclaration(2 params) calling both QnH and kj6, contains "xhigh"/"max"/"high" literals
#   za:  FunctionDeclaration(3 params) single return with === "xhigh" comparison
#
# Verified: v2.1.162
#
# Usage:
#   ./apply-claude-code-unlock-ultracode-fix.sh                    # Apply (auto-detect)
#   ./apply-claude-code-unlock-ultracode-fix.sh /path/to/cli.js   # Apply to specific file
#   ./apply-claude-code-unlock-ultracode-fix.sh --check            # Check only
#   ./apply-claude-code-unlock-ultracode-fix.sh --restore          # Restore backup
#

set -e

# ============================================================
# Configuration
# ============================================================
BACKUP_SUFFIX="backup-ultracode"
FIX_DESCRIPTION="Unlock ultracode for max-capable models (opus-4-6, sonnet-4-6)"

# ============================================================
# Color output functions
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[X]${NC} $1"; }
info() { echo -e "${BLUE}[>]${NC} $1"; }

# ============================================================
# Argument parsing
# ============================================================
CHECK_ONLY=false
RESTORE=false
CLI_PATH_ARG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --check|-c) CHECK_ONLY=true; shift ;;
        --restore|-r) RESTORE=true; shift ;;
        --help|-h)
            echo "Usage: $0 [options] [cli.js path]"
            echo ""
            echo "$FIX_DESCRIPTION"
            echo ""
            echo "Arguments:"
            echo "  cli.js path    Path to cli.js file (optional, auto-detect if not provided)"
            echo ""
            echo "Options:"
            echo "  --check, -c    Check if fix is needed without making changes"
            echo "  --restore, -r  Restore original file from backup"
            echo "  --help, -h     Show help information"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Auto-detect and apply fix"
            echo "  $0 /path/to/cli.js                    # Apply fix to specific file"
            echo "  $0 --check /path/to/cli.js            # Check specific file"
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -z "$CLI_PATH_ARG" ]]; then
                CLI_PATH_ARG="$1"
            else
                error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# ============================================================
# Find Claude Code cli.js path
# ============================================================
find_cli_path() {
    local locations=(
        "$HOME/.claude/local/node_modules/@cometix/claude-code/cli.js"
        "/usr/local/lib/node_modules/@cometix/claude-code/cli.js"
        "/usr/lib/node_modules/@cometix/claude-code/cli.js"
    )
    if command -v npm &> /dev/null; then
        local npm_root
        npm_root=$(npm root -g 2>/dev/null || true)
        if [[ -n "$npm_root" ]]; then
            locations+=("$npm_root/@cometix/claude-code/cli.js")
        fi
    fi
    for path in "${locations[@]}"; do
        if [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

if [[ -n "$CLI_PATH_ARG" ]]; then
    if [[ -f "$CLI_PATH_ARG" ]]; then
        CLI_PATH="$CLI_PATH_ARG"
        info "Using specified cli.js: $CLI_PATH"
    else
        error "Specified file not found: $CLI_PATH_ARG"
        exit 1
    fi
else
    CLI_PATH=$(find_cli_path) || {
        error "Claude Code cli.js not found"
        echo ""
        echo "Searched locations:"
        echo "  ~/.claude/local/node_modules/@cometix/claude-code/cli.js"
        echo "  /usr/local/lib/node_modules/@cometix/claude-code/cli.js"
        echo "  \$(npm root -g)/@cometix/claude-code/cli.js"
        echo ""
        echo "Tip: You can specify the path directly:"
        echo "  $0 /path/to/cli.js"
        exit 1
    }
    info "Found Claude Code: $CLI_PATH"
fi

CLI_DIR=$(dirname "$CLI_PATH")

# ============================================================
# Restore backup
# ============================================================
if $RESTORE; then
    LATEST_BACKUP=$(ls -t "$CLI_DIR"/cli.js.${BACKUP_SUFFIX}-* 2>/dev/null | head -1)
    if [[ -n "$LATEST_BACKUP" ]]; then
        cp "$LATEST_BACKUP" "$CLI_PATH"
        success "Restored from backup: $LATEST_BACKUP"
        exit 0
    else
        error "No backup file found (cli.js.${BACKUP_SUFFIX}-*)"
        exit 1
    fi
fi

echo ""

# ============================================================
# Download acorn parser if needed
# ============================================================
ACORN_PATH="/tmp/acorn-claude-fix.js"
if [[ ! -f "$ACORN_PATH" ]]; then
    info "Downloading acorn parser..."
    curl -sL "https://unpkg.com/acorn@8.16.0/dist/acorn.js" -o "$ACORN_PATH" || {
        error "Failed to download acorn parser"
        exit 1
    }
fi

# ============================================================
# Node.js patch script
# ============================================================
PATCH_SCRIPT=$(mktemp)
cat > "$PATCH_SCRIPT" << 'PATCH_EOF'
const fs = require('fs');
const acorn = require(process.argv[2]);
const cliPath = process.argv[3];
const checkOnly = process.argv[4] === '--check';
const backupSuffix = process.env.BACKUP_SUFFIX || 'backup';

let code = fs.readFileSync(cliPath, 'utf-8');

let shebang = '';
if (code.startsWith('#!')) {
    const idx = code.indexOf('\n');
    shebang = code.slice(0, idx + 1);
    code = code.slice(idx + 1);
}

let version = 'unknown';
const headerMatch = code.slice(0, 1000).match(/Version:\s*([\d.]+)/);
if (headerMatch) {
    version = headerMatch[1];
} else {
    const path = require('path');
    try {
        const pkg = JSON.parse(fs.readFileSync(path.join(path.dirname(cliPath), 'package.json'), 'utf-8'));
        if (pkg.version) version = pkg.version;
    } catch {}
}
console.log('VERSION:' + version);

// ============================================================
// Parse AST
// ============================================================
let ast;
try {
    ast = acorn.parse(code, { ecmaVersion: 'latest', sourceType: 'module' });
} catch (e) {
    console.error('PARSE_ERROR:' + e.message);
    process.exit(1);
}

function findNodes(node, predicate, results = []) {
    if (!node || typeof node !== 'object') return results;
    if (predicate(node)) results.push(node);
    for (const key in node) {
        if (key === 'start' || key === 'end' || key === 'type') continue;
        if (node[key] && typeof node[key] === 'object') {
            if (Array.isArray(node[key])) {
                node[key].forEach(child => findNodes(child, predicate, results));
            } else {
                findNodes(node[key], predicate, results);
            }
        }
    }
    return results;
}

const src = (node) => code.slice(node.start, node.end);

function replaceAt(str, s, e, repl) {
    return str.slice(0, s) + repl + str.slice(e);
}

let replacements = [];
let patchCount = 0;
let patchedFlags = { gu: false, oa: false, za: false };

// ============================================================
// Phase 1: Find anchor functions by their capability literals
//
// QnH: FunctionDeclaration(1 param) containing "xhigh_effort"
// kj6: FunctionDeclaration(1 param) containing "max_effort"
// ============================================================
console.log('STEP:1 - Finding anchor functions (xhigh_effort + max_effort gates)');

const allFunc1 = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' && n.params.length === 1
);

function findGateFunc(funcs, literal) {
    return funcs.filter(fn =>
        findNodes(fn.body, n =>
            n.type === 'CallExpression' &&
            n.arguments && n.arguments.length >= 2 &&
            n.arguments[1].type === 'Literal' &&
            n.arguments[1].value === literal
        ).length > 0
    );
}

const xhighCandidates = findGateFunc(allFunc1, 'xhigh_effort');
if (xhighCandidates.length === 0) {
    console.error('NOT_FOUND:Cannot find xhigh_effort gate function');
    process.exit(1);
}
const qnhFunc = xhighCandidates[0];
const qnhName = qnhFunc.id.name;
console.log('FOUND:QnH = ' + qnhName + '() — xhigh_effort gate');

const maxCandidates = findGateFunc(allFunc1, 'max_effort');
if (maxCandidates.length === 0) {
    console.error('NOT_FOUND:Cannot find max_effort gate function');
    process.exit(1);
}
const kj6Func = maxCandidates[0];
const kj6Name = kj6Func.id.name;
console.log('FOUND:kj6 = ' + kj6Name + '() — max_effort gate');

// ============================================================
// Phase 2: Find and patch Gu() — ultracode availability
//
// AST: FunctionDeclaration(1 param), single return,
//      calls QnH by name, has === void 0 check
//
// Patch: QnH(H) → QnH(H) || kj6(H)
// ============================================================
console.log('STEP:2 - Finding Gu() — ultracode availability gate');

const guCandidates = allFunc1.filter(fn => {
    const body = fn.body.body;
    if (!body || body.length !== 1 || body[0].type !== 'ReturnStatement') return false;
    const qnhCalls = findNodes(fn.body, n =>
        n.type === 'CallExpression' &&
        n.callee.type === 'Identifier' &&
        n.callee.name === qnhName
    );
    if (qnhCalls.length !== 1) return false;
    const voidChecks = findNodes(fn.body, n =>
        n.type === 'BinaryExpression' && n.operator === '===' &&
        ((n.right.type === 'UnaryExpression' && n.right.operator === 'void') ||
         (n.left.type === 'UnaryExpression' && n.left.operator === 'void'))
    );
    return voidChecks.length > 0;
});

if (guCandidates.length === 0) {
    console.error('NOT_FOUND:Cannot find Gu() — no 1-param FuncDecl calling ' + qnhName + ' with void 0 check');
    process.exit(1);
}

const guFunc = guCandidates[0];
const guName = guFunc.id.name;
const guParam = guFunc.params[0].name;
console.log('FOUND:Gu = ' + guName + '(' + guParam + ') at offset ' + guFunc.start);

const guQnhCall = findNodes(guFunc.body, n =>
    n.type === 'CallExpression' &&
    n.callee.type === 'Identifier' &&
    n.callee.name === qnhName
)[0];

// Check if already patched (kj6 call already present)
const guKj6Calls = findNodes(guFunc.body, n =>
    n.type === 'CallExpression' &&
    n.callee.type === 'Identifier' &&
    n.callee.name === kj6Name
);

if (guKj6Calls.length > 0) {
    console.log('FOUND:Gu already has ' + kj6Name + '() call — skipping');
    patchedFlags.gu = true;
} else {
    const addition = '||' + kj6Name + '(' + guParam + ')';
    replacements.push({
        start: guQnhCall.end,
        end: guQnhCall.end,
        replacement: addition,
        label: 'Gu: ' + qnhName + '(' + guParam + ') → ' + qnhName + '(' + guParam + ')' + addition
    });
    patchCount++;
    console.log('FOUND:Gu needs patching — adding ' + kj6Name + ' fallback');
}

// ============================================================
// Phase 3: Find and patch Oa() — effort resolver
//
// AST: FunctionDeclaration(2 params), calls both QnH and kj6,
//      contains string literals "xhigh", "max", "high"
//
// Target: the IfStatement where test is `L === "xhigh" && !QnH(H)`
//         and consequent returns "high".
// Patch: return "high" → return kj6(H) ? "max" : "high"
// ============================================================
console.log('STEP:3 - Finding Oa() — effort resolver');

const allFunc2 = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' && n.params.length === 2
);

const oaCandidates = allFunc2.filter(fn => {
    const callsQnH = findNodes(fn.body, n =>
        n.type === 'CallExpression' &&
        n.callee.type === 'Identifier' &&
        n.callee.name === qnhName
    ).length > 0;
    const callsKj6 = findNodes(fn.body, n =>
        n.type === 'CallExpression' &&
        n.callee.type === 'Identifier' &&
        n.callee.name === kj6Name
    ).length > 0;
    if (!callsQnH || !callsKj6) return false;
    const hasXhigh = findNodes(fn.body, n =>
        n.type === 'Literal' && n.value === 'xhigh'
    ).length > 0;
    const hasMax = findNodes(fn.body, n =>
        n.type === 'Literal' && n.value === 'max'
    ).length > 0;
    const hasHigh = findNodes(fn.body, n =>
        n.type === 'Literal' && n.value === 'high'
    ).length > 0;
    return hasXhigh && hasMax && hasHigh;
});

if (oaCandidates.length === 0) {
    console.error('NOT_FOUND:Cannot find Oa() — no 2-param FuncDecl calling both ' + qnhName + ' and ' + kj6Name);
    process.exit(1);
}

const oaFunc = oaCandidates[0];
const oaName = oaFunc.id.name;
const oaModelParam = oaFunc.params[0].name;
console.log('FOUND:Oa = ' + oaName + '(' + oaModelParam + ', ...) at offset ' + oaFunc.start);

// Find the xhigh degradation IfStatement:
//   if (L === "xhigh" && !QnH(H)) return "high"
const oaIfStmts = findNodes(oaFunc.body, n => n.type === 'IfStatement');

let xhighDegradeIf = null;
let xhighDegradeReturn = null;

for (const ifStmt of oaIfStmts) {
    if (ifStmt.test.type !== 'LogicalExpression' || ifStmt.test.operator !== '&&') continue;

    const left = ifStmt.test.left;
    if (left.type !== 'BinaryExpression' || left.operator !== '===' ||
        !(left.right?.type === 'Literal' && left.right.value === 'xhigh')) continue;

    const right = ifStmt.test.right;
    if (right.type !== 'UnaryExpression' || right.operator !== '!') continue;
    if (right.argument?.type !== 'CallExpression' ||
        right.argument.callee?.name !== qnhName) continue;

    // Found the xhigh degradation IfStatement — inspect consequent
    xhighDegradeIf = ifStmt;

    // Three shapes: return "high" | i="high" | i=gBe(e)?"max":"high" (2.1.204 patched)
    let retStmt = null;
    let assignExpr = null;
    const cons = ifStmt.consequent;
    if (cons.type === 'ReturnStatement') retStmt = cons;
    else if (cons.type === 'BlockStatement' &&
             cons.body.length === 1 &&
             cons.body[0].type === 'ReturnStatement') {
        retStmt = cons.body[0];
    } else if (cons.type === 'ExpressionStatement' &&
               cons.expression.type === 'AssignmentExpression' &&
               cons.expression.operator === '=') {
        assignExpr = cons.expression;
    } else if (cons.type === 'BlockStatement' &&
               cons.body.length === 1 &&
               cons.body[0].type === 'ExpressionStatement' &&
               cons.body[0].expression.type === 'AssignmentExpression' &&
               cons.body[0].expression.operator === '=') {
        assignExpr = cons.body[0].expression;
    }
    if (!retStmt && !assignExpr) break;

    function isKj6MaxHighConditional(cond) {
        const testCallsKj6 = cond?.type === 'ConditionalExpression' &&
            cond.test?.type === 'CallExpression' &&
            cond.test.callee?.type === 'Identifier' &&
            cond.test.callee.name === kj6Name;
        const consequentIsMax = cond?.consequent?.type === 'Literal' &&
            cond.consequent.value === 'max';
        const altIsHigh = cond?.alternate?.type === 'Literal' &&
            cond.alternate.value === 'high';
        return testCallsKj6 && consequentIsMax && altIsHigh;
    }

    if (retStmt) {
        if (retStmt.argument?.type === 'Literal' && retStmt.argument.value === 'high') {
            xhighDegradeReturn = retStmt.argument;
        } else if (isKj6MaxHighConditional(retStmt.argument)) {
            console.log('FOUND:' + oaName + ' xhigh degradation already patched (' + kj6Name + '→"max")');
            patchedFlags.oa = true;
        }
    } else if (assignExpr) {
        if (assignExpr.right?.type === 'Literal' && assignExpr.right.value === 'high') {
            xhighDegradeReturn = assignExpr.right;
        } else if (isKj6MaxHighConditional(assignExpr.right)) {
            console.log('FOUND:' + oaName + ' xhigh degradation already patched (' + kj6Name + '→"max") [assign form]');
            patchedFlags.oa = true;
        }
    }
    break;
}

if (!xhighDegradeIf) {
    console.error('NOT_FOUND:Cannot find xhigh degradation IfStatement (==="xhigh"&&!' + qnhName + ') in ' + oaName + '()');
    process.exit(1);
}

if (!patchedFlags.oa && xhighDegradeReturn) {
    console.log('FOUND:xhigh degradation at offset ' + xhighDegradeIf.start +
                ' — "high" → ' + kj6Name + '(' + oaModelParam + ')?"max":"high"');

    // Ensure space after `return` — minified code may have `return"high"` (no space)
    const charBefore = code[xhighDegradeReturn.start - 1];
    const spacer = (charBefore && /[a-zA-Z_$0-9]/.test(charBefore)) ? ' ' : '';

    replacements.push({
        start: xhighDegradeReturn.start,
        end: xhighDegradeReturn.end,
        replacement: spacer + kj6Name + '(' + oaModelParam + ')?"max":"high"',
        label: oaName + ': xhigh degrade "high" → ' + kj6Name + '(…)?"max":"high"'
    });
    patchCount++;
} else if (!patchedFlags.oa) {
    console.error('NOT_FOUND:Unexpected return structure in xhigh degradation of ' + oaName + '()');
    process.exit(1);
}

// ============================================================
// Phase 4: Find and patch za() — ultracode active check
//
// AST: FunctionDeclaration(3 params), single return statement,
//      contains BinaryExpression === "xhigh"
//
// Patch: Oa(H,_)==="xhigh" → (Oa(H,_)==="xhigh"||Oa(H,_)==="max")
// ============================================================
console.log('STEP:4 - Finding za() — ultracode active check');

const allFunc3 = findNodes(ast, n =>
    n.type === 'FunctionDeclaration' && n.params.length === 3
);

const zaCandidates = allFunc3.filter(fn => {
    const body = fn.body.body;
    if (!body || body.length !== 1 || body[0].type !== 'ReturnStatement') return false;
    const xhighComps = findNodes(fn.body, n =>
        n.type === 'BinaryExpression' && n.operator === '===' &&
        ((n.right?.type === 'Literal' && n.right.value === 'xhigh') ||
         (n.left?.type === 'Literal' && n.left.value === 'xhigh'))
    );
    return xhighComps.length > 0;
});

if (zaCandidates.length === 0) {
    console.error('NOT_FOUND:Cannot find za() — no 3-param FuncDecl with single return containing === "xhigh"');
    process.exit(1);
}
{
    const zaFunc = zaCandidates[0];
    const zaName = zaFunc.id.name;
    console.log('FOUND:za = ' + zaName + '(' + zaFunc.params.map(p => p.name).join(', ') + ') at offset ' + zaFunc.start);

    // Find the === "xhigh" comparison
    const xhighComp = findNodes(zaFunc.body, n =>
        n.type === 'BinaryExpression' && n.operator === '===' &&
        n.right?.type === 'Literal' && n.right.value === 'xhigh'
    )[0];

    if (!xhighComp) {
        console.error('NOT_FOUND:Cannot find === "xhigh" comparison in ' + zaName);
        process.exit(1);
    }

    // Check if already patched: look for "max" comparison in same function
    const maxComps = findNodes(zaFunc.body, n =>
        n.type === 'BinaryExpression' && n.operator === '===' &&
        n.right?.type === 'Literal' && n.right.value === 'max'
    );

    if (maxComps.length > 0) {
        console.log('FOUND:za already accepts "max" — skipping');
        patchedFlags.za = true;
    } else {
        // The comparison is: Oa(H,_)==="xhigh"
        // Replace with: (Oa(H,_)==="xhigh"||Oa(H,_)==="max")
        const oaCallSrc = src(xhighComp.left);
        const fullComparison = src(xhighComp);
        const replacement = '(' + fullComparison + '||' + oaCallSrc + '==="max")';

        replacements.push({
            start: xhighComp.start,
            end: xhighComp.end,
            replacement: replacement,
            label: 'za: ' + fullComparison + ' → ' + replacement
        });
        patchCount++;
        console.log('FOUND:za needs patching — adding "max" acceptance');
    }
}

// ============================================================
// All already patched?
// ============================================================
if (patchedFlags.gu && patchedFlags.oa && patchedFlags.za) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

if (replacements.length === 0) {
    console.log('ALREADY_PATCHED');
    process.exit(2);
}

// ============================================================
// Check-only mode
// ============================================================
if (checkOnly) {
    console.log('NEEDS_PATCH');
    console.log('PATCH_COUNT:' + patchCount);
    process.exit(1);
}

// ============================================================
// Phase 5: Apply replacements (end-to-start order)
// ============================================================
console.log('STEP:5 - Applying ' + replacements.length + ' replacement(s)');

replacements.sort((a, b) => b.start - a.start);

let newCode = code;
for (const r of replacements) {
    newCode = replaceAt(newCode, r.start, r.end, r.replacement);
    console.log('PATCH:' + r.label);
}

// ============================================================
// Phase 6: Verify
// ============================================================

// 6a. Re-parse
let newAst;
try {
    newAst = acorn.parse(newCode, { ecmaVersion: 'latest', sourceType: 'module' });
    console.log('VERIFY:AST re-parse OK');
} catch (e) {
    console.error('VERIFY_FAILED:Patched code fails to parse: ' + e.message);
    process.exit(1);
}

// 6b. Verify Gu now calls kj6
if (!patchedFlags.gu) {
    const patchedGu = findNodes(newAst, n =>
        n.type === 'FunctionDeclaration' && n.id.name === guName
    )[0];
    if (!patchedGu) {
        console.error('VERIFY_FAILED:' + guName + ' not found after patch');
        process.exit(1);
    }
    const kj6InGu = findNodes(patchedGu.body, n =>
        n.type === 'CallExpression' &&
        n.callee.type === 'Identifier' &&
        n.callee.name === kj6Name
    );
    if (kj6InGu.length === 0) {
        console.error('VERIFY_FAILED:' + guName + ' does not call ' + kj6Name + ' after patch');
        process.exit(1);
    }
    console.log('VERIFY:' + guName + ' now calls ' + kj6Name + '()');
}

// 6c. Verify Oa xhigh degradation has kj6 conditional
if (!patchedFlags.oa) {
    const patchedOa = findNodes(newAst, n =>
        n.type === 'FunctionDeclaration' && n.id.name === oaName
    )[0];
    if (!patchedOa) {
        console.error('VERIFY_FAILED:' + oaName + ' not found after patch');
        process.exit(1);
    }
    const condExprs = findNodes(patchedOa.body, n =>
        n.type === 'ConditionalExpression' &&
        n.test?.type === 'CallExpression' &&
        n.test.callee?.type === 'Identifier' &&
        n.test.callee.name === kj6Name &&
        n.consequent?.type === 'Literal' &&
        n.consequent.value === 'max'
    );
    if (condExprs.length === 0) {
        console.error('VERIFY_FAILED:' + oaName + ' missing ' + kj6Name + '(…)?"max":"high" conditional');
        process.exit(1);
    }
    console.log('VERIFY:' + oaName + ' xhigh degradation now falls to "max" when supported');
}

// 6d. Verify za accepts "max"
if (!patchedFlags.za) {
    const patchedZaName = zaCandidates[0].id.name;
    const patchedZa = findNodes(newAst, n =>
        n.type === 'FunctionDeclaration' && n.id.name === patchedZaName
    )[0];
    if (!patchedZa) {
        console.error('VERIFY_FAILED:' + patchedZaName + ' not found after patch');
        process.exit(1);
    }
    const maxCompsVerify = findNodes(patchedZa.body, n =>
        n.type === 'BinaryExpression' && n.operator === '===' &&
        ((n.right?.type === 'Literal' && n.right.value === 'max') ||
         (n.left?.type === 'Literal' && n.left.value === 'max'))
    );
    if (maxCompsVerify.length === 0) {
        console.error('VERIFY_FAILED:' + patchedZaName + ' does not accept "max" after patch');
        process.exit(1);
    }
    console.log('VERIFY:' + patchedZaName + ' now accepts "max" as valid ultracode effort');
}

// ============================================================
// Backup and write
// ============================================================
const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const backupPath = cliPath + '.' + backupSuffix + '-' + timestamp;
fs.copyFileSync(cliPath, backupPath);
console.log('BACKUP:' + backupPath);

fs.writeFileSync(cliPath, shebang + newCode);
console.log('FUNC_NAMES:' + guName + '|' + oaName + '|' + zaCandidates[0].id.name);
console.log('SUCCESS:' + patchCount);
PATCH_EOF

# ============================================================
# Execute patch script
# ============================================================
CHECK_ARG=""
if $CHECK_ONLY; then
    CHECK_ARG="--check"
fi

export BACKUP_SUFFIX
OUTPUT=$(node "$PATCH_SCRIPT" "$ACORN_PATH" "$CLI_PATH" "$CHECK_ARG" 2>&1) || true
EXIT_CODE=$?

rm -f "$PATCH_SCRIPT"

# ============================================================
# Process output
# ============================================================
FN_GU="" FN_OA="" FN_ZA=""
while IFS= read -r line; do
    case "$line" in
        ALREADY_PATCHED)
            success "Already patched"
            exit 0
            ;;
        PARSE_ERROR:*)
            error "Failed to parse cli.js: ${line#PARSE_ERROR:}"
            exit 1
            ;;
        NOT_FOUND:*)
            error "Target code not found: ${line#NOT_FOUND:}"
            exit 1
            ;;
        VERSION:*)
            info "Claude Code version: ${line#VERSION:}"
            ;;
        STEP:*)
            info "Step ${line#STEP:}"
            ;;
        FOUND:*)
            info "Found: ${line#FOUND:}"
            ;;
        VERIFY:*)
            info "Verify: ${line#VERIFY:}"
            ;;
        PATCH:*)
            info "  ${line#PATCH:}"
            ;;
        NEEDS_PATCH)
            echo ""
            warning "Patch needed - run without --check to apply"
            ;;
        PATCH_COUNT:*)
            info "Need to patch ${line#PATCH_COUNT:} location(s)"
            exit 1
            ;;
        FUNC_NAMES:*)
            IFS='|' read -r FN_GU FN_OA FN_ZA <<< "${line#FUNC_NAMES:}"
            ;;
        BACKUP:*)
            echo ""
            echo "Backup: ${line#BACKUP:}"
            ;;
        SUCCESS:*)
            echo ""
            success "Ultracode unlocked! Patched ${line#SUCCESS:} location(s)"
            echo ""
            echo "  Patch 1: ${FN_GU}() — ultracode available for max-capable models"
            echo "  Patch 2: ${FN_OA}() — xhigh degrades to max (not high) when supported"
            echo "  Patch 3: ${FN_ZA}() — accepts max as valid ultracode effort"
            echo ""
            echo "  Flow: /effort ultracode → xhigh → ${FN_OA} degrades → max → ultracode active"
            echo ""
            warning "Restart Claude Code for changes to take effect"
            ;;
        VERIFY_FAILED:*)
            error "Verification failed: ${line#VERIFY_FAILED:}"
            exit 1
            ;;
    esac
done <<< "$OUTPUT"

exit $EXIT_CODE
