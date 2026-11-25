#!/usr/bin/env python3
"""Police Curfew's four ledgers.

Four records keep this project honest: the known-issues ledger (KI ids), the
design-decisions ledger (D ids), the contract ledger (module offers/expects),
and the decomposition ledger (L layer.atom ids). Each has invariants a machine
can check, and a ledger whose invariants are not checked is a document, not a
ledger. Run this before committing a ledger change and in the session recap.

Exit 0 when every ledger is consistent; 1 otherwise.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KI = ROOT / "docs" / "known-issues.md"
DECISIONS = ROOT / "docs" / "plans" / "CURFEW-DESIGN-DECISIONS.md"
CONTRACTS = ROOT / "docs" / "plans" / "CURFEW-CONTRACTS.md"
DECOMPOSITION = ROOT / "docs" / "plans" / "CURFEW-DECOMPOSITION.md"

SEVERITIES = {"blocker", "defect", "gap", "improvement", "environmental", "risk"}
STATUSES = {"planned", "drafted", "building", "done"}
BLOCK_STARTS = ("OFFERS", "EXPECTS", "CONSUMED BY", "```", "## ")

problems: list[str] = []
counts: dict[str, int] = {}


def fail(where: str, msg: str) -> None:
    problems.append(f"{where}: {msg}")


def table_cells(line: str) -> list[str]:
    r"""Split a markdown row on unescaped pipes.

    Prose about shell pipelines is legitimate in a ledger row (KI-031 is exactly that), and a
    literal pipe is escaped as \|. Splitting naively counts the escape and reports a malformed
    row — which is how this check first failed on its own subject matter.
    """
    body = line.strip().strip("|")
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", body)]


def check_known_issues() -> None:
    if not KI.exists():
        fail(str(KI), "missing")
        return
    ids: list[int] = []
    for n, line in enumerate(KI.read_text().splitlines(), 1):
        if not line.startswith("| KI-"):
            continue
        cells = table_cells(line)
        if len(cells) != 6:
            fail(f"known-issues.md:{n}", f"{len(cells)} cells, expected 6 (escape any literal pipe as \\|)")
            continue
        ki_id, severity, issue, evidence, status, action = cells
        m = re.fullmatch(r"KI-(\d+)", ki_id)
        if not m:
            fail(f"known-issues.md:{n}", f"malformed id {ki_id!r}")
            continue
        ids.append(int(m.group(1)))
        if severity not in SEVERITIES:
            fail(f"known-issues.md:{n}", f"{ki_id} severity {severity!r} not in the six-word vocabulary")
        for name, cell in (("issue", issue), ("evidence", evidence), ("status", status), ("next action", action)):
            if not cell:
                fail(f"known-issues.md:{n}", f"{ki_id} empty {name} cell")
    dupes = {i for i in ids if ids.count(i) > 1}
    if dupes:
        fail("known-issues.md", f"duplicate ids: {sorted(dupes)}")
    if ids and ids != list(range(1, len(ids) + 1)):
        missing = sorted(set(range(1, max(ids) + 1)) - set(ids))
        fail("known-issues.md", f"ids are not 1..{max(ids)}; missing {missing}")
    counts["known-issues"] = len(ids)


def check_decisions() -> dict[int, str]:
    """Return {D id: entry text} after checking the entries' shape."""
    entries: dict[int, str] = {}
    if not DECISIONS.exists():
        fail(str(DECISIONS), "missing")
        return entries
    lines = DECISIONS.read_text().splitlines()
    current: int | None = None
    buffer: list[str] = []

    def flush() -> None:
        if current is None:
            return
        text = "\n".join(buffer)
        if "Rationale:" not in text:
            fail("CURFEW-DESIGN-DECISIONS.md", f"D{current} has no Rationale:")
        if "Constrains:" not in text:
            fail("CURFEW-DESIGN-DECISIONS.md", f"D{current} has no Constrains:")
        for ref in re.findall(r"supersed\w*\s+D(\d+)", text, re.I):
            if int(ref) not in entries and int(ref) != current:
                fail("CURFEW-DESIGN-DECISIONS.md", f"D{current} supersedes D{ref}, which does not exist")
        entries[current] = text

    for line in lines:
        m = re.match(r"^-\s+\*\*D(\d+)\s+—", line)
        if m:
            flush()
            current = int(m.group(1))
            if current in entries:
                fail("CURFEW-DESIGN-DECISIONS.md", f"duplicate D{current}")
            buffer = [line]
        elif current is not None and not line.startswith("## "):
            buffer.append(line)
        elif current is not None and line.startswith("## "):
            flush()
            current, buffer = None, []
    flush()
    counts["design-decisions"] = len(entries)
    return entries


def block(lines: list[str], start: int, prefix: str) -> str:
    """Collect a ledger block: the line starting with `prefix` plus continuations, minus the keyword."""
    out = [lines[start]]
    for line in lines[start + 1:]:
        stripped = line.strip()
        if not stripped or stripped.startswith(BLOCK_STARTS):
            break
        if line.startswith((" ", "\t")):
            out.append(line)
        else:
            break
    text = "\n".join(out)
    # drop the block's own keyword so a symbol on the first line parses like any other
    return re.sub(r"^\s*(OFFERS|EXPECTS|CONSUMED BY)\s+", "", text, count=1)


def check_contracts() -> dict[int, dict[str, str]]:
    sections: dict[int, dict[str, str]] = {}
    if not CONTRACTS.exists():
        fail(str(CONTRACTS), "missing")
        return sections
    lines = CONTRACTS.read_text().splitlines()
    current: int | None = None
    for n, line in enumerate(lines):
        m = re.match(r"^## C(\d+)\b", line)
        if m:
            current = int(m.group(1))
            sections[current] = {"offers": "", "expects": "", "consumed": "", "line": str(n + 1)}
            continue
        if current is None:
            continue
        s = line.lstrip()
        if s.startswith("OFFERS"):
            sections[current]["offers"] = block(lines, n, "OFFERS")
        elif s.startswith("EXPECTS"):
            sections[current]["expects"] = block(lines, n, "EXPECTS")
        elif s.startswith("CONSUMED BY"):
            sections[current]["consumed"] = block(lines, n, "CONSUMED BY")

    for cid, sec in sections.items():
        for field in ("offers", "expects", "consumed"):
            if not sec[field]:
                fail(f"contracts C{cid}", f"missing {field.upper()} block")

    for cid, sec in sections.items():
        for segment in re.split(r"·|\n", sec["expects"]):
            ref = re.search(r"\(C(\d+)\)", segment)
            if not ref:
                continue
            target = int(ref.group(1))
            symbol = segment[: ref.start()].strip()
            symbol = symbol.split("::")[-1].strip()
            if not symbol:
                fail(f"contracts C{cid}", f"EXPECTS reference to C{target} names no symbol")
                continue
            if target not in sections:
                fail(f"contracts C{cid}", f"EXPECTS names C{target}, which does not exist")
                continue
            if symbol not in sections[target]["offers"]:
                fail(
                    f"contracts C{cid}",
                    f"broken seam: EXPECTS {symbol!r} from C{target}, but C{target} does not OFFER it",
                )
    counts["contracts"] = len(sections)
    return sections


def check_decomposition(decisions: dict[int, str]) -> None:
    if not DECOMPOSITION.exists():
        fail(str(DECOMPOSITION), "missing")
        return
    atoms: dict[str, int] = {}
    rows: list[tuple[int, str, list[str]]] = []
    for n, line in enumerate(DECOMPOSITION.read_text().splitlines(), 1):
        if not line.startswith("| L"):
            continue
        cells = table_cells(line)
        if len(cells) != 6:
            fail(f"decomposition:{n}", f"{len(cells)} cells, expected 6 (atom, builds, depends, choices, status, evidence)")
            continue
        atom = cells[0]
        if not re.fullmatch(r"L\d+\.\d+", atom):
            fail(f"decomposition:{n}", f"malformed atom id {atom!r}")
            continue
        if atom in atoms:
            fail(f"decomposition:{n}", f"duplicate atom {atom}")
        atoms[atom] = n
        rows.append((n, atom, cells))

    for n, atom, cells in rows:
        _, builds, depends, choices, status, proof = cells
        if not builds:
            fail(f"decomposition:{n}", f"{atom} has an empty Builds cell")
        if status not in STATUSES:
            fail(f"decomposition:{n}", f"{atom} status {status!r} not in {sorted(STATUSES)}")
        # The house rule: a status flips to done only with a pointer to the proof. Without
        # this, a typo — or a grep that ran too wide — can claim a layer that does not exist.
        if status == "done" and proof.strip() in ("", "—", "-"):
            fail(f"decomposition:{n}", f"{atom} is marked done with no Evidence — cite the file, test or measurement")
        for dep in re.split(r"[,·\s]+", depends):
            dep = dep.strip()
            if dep in ("", "—", "-"):
                continue
            if dep not in atoms:
                fail(f"decomposition:{n}", f"{atom} depends on undefined atom {dep!r}")
        for choice in re.findall(r"D(\d+)", choices):
            if int(choice) not in decisions:
                fail(f"decomposition:{n}", f"{atom} cites D{choice}, which the decisions ledger does not define")
    counts["atoms"] = len(atoms)


def main() -> int:
    decisions = check_decisions()
    check_known_issues()
    check_contracts()
    check_decomposition(decisions)

    total = sum(counts.values())
    if problems:
        print(f"LEDGERS: FAIL — {len(problems)} problem(s) across {total} checked units\n")
        for p in problems:
            print(f"  ✗ {p}")
        return 1
    summary = " · ".join(f"{k} {v}" for k, v in counts.items())
    print(f"LEDGERS: ok — {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
