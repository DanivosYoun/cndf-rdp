#!/usr/bin/env python3
"""Create or verify a measurement-only CAN_LOCK-off scratch copy of cndf-rdp (design L-W4).

NEVER commit or tag a CAN_LOCK-off tree as a product release. This script operates on a
separate scratch copy (excluding .git/.build/target) and writes a sentinel file so the
scratch tree cannot be mistaken for a product checkout.

Usage:
  can-lock-off.py --src <cndf-rdp-tree> --dest <scratch-dir>
  can-lock-off.py --src <cndf-rdp-tree> --dry-run
  can-lock-off.py --check <tree>
"""
import argparse
import difflib
import os
import re
import shutil
import sys

RUST_REL = os.path.join("Rust", "cndf-ironrdp", "src", "clipboard.rs")
C_REL = os.path.join("Sources", "FreeRDPBridge", "FreeRDPBridge.c")
SENTINEL = ".CAN_LOCK_OFF_SCRATCH_DO_NOT_SHIP"

RUST_FN_RE = re.compile(
    r"(fn\s+client_capabilities\s*\(&self\)\s*->\s*Capabilities\s*\{)(.*?)(\n\s*\})",
    re.DOTALL,
)
C_FLAGS_RE = re.compile(
    r"(general\.generalFlags\s*=\s*)(.*?)(;)",
    re.DOTALL,
)


def strip_flag_expr(expr: str, token: str) -> tuple[str, int]:
    """Remove `token` from a bitwise-OR expression (single-line or multi-line)."""
    count = len(re.findall(rf"\b{re.escape(token)}\b", expr))
    if count == 0:
        return expr, 0

    # 1. Trailing `| <token>` (possibly spanning a newline with indentation)
    out = re.sub(rf"\s*\|\s*{re.escape(token)}\b", "", expr)
    # 2. Leading `<token> |` (when token was the first item)
    out = re.sub(rf"\b{re.escape(token)}\s*\|\s*", "", out)
    # 3. Clean up any accidental blank lines inside the expression
    out = re.sub(r"\n[ \t]*\n", "\n", out)
    return out, count


def transform_rust_clipboard(text: str) -> tuple[str, int]:
    m = RUST_FN_RE.search(text)
    if not m:
        raise ValueError("fn client_capabilities(&self) -> Capabilities not found in clipboard.rs")
    new_body, count = strip_flag_expr(m.group(2), "Capabilities::CAN_LOCK_CLIPDATA")
    updated = text[: m.start(2)] + new_body + text[m.end(2) :]
    return updated, count


def transform_c_bridge(text: str) -> tuple[str, int]:
    m = C_FLAGS_RE.search(text)
    if not m:
        raise ValueError("general.generalFlags = ...; not found in FreeRDPBridge.c")
    new_expr, count = strip_flag_expr(m.group(2), "CB_CAN_LOCK_CLIPDATA")
    updated = text[: m.start(2)] + new_expr + text[m.end(2) :]
    return updated, count


def check_tree(root: str) -> list[str]:
    problems = []
    rust_path = os.path.join(root, RUST_REL)
    c_path = os.path.join(root, C_REL)
    for rel, path, fn_re, token in (
        (RUST_REL, rust_path, RUST_FN_RE, "Capabilities::CAN_LOCK_CLIPDATA"),
        (C_REL, c_path, C_FLAGS_RE, "CB_CAN_LOCK_CLIPDATA"),
    ):
        if not os.path.isfile(path):
            problems.append(f"missing {rel}")
            continue
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        m = fn_re.search(text)
        if not m:
            problems.append(f"capability block not found in {rel}")
            continue
        if re.search(rf"\b{re.escape(token)}\b", m.group(2)):
            problems.append(f"{rel} still advertises {token}")
    return problems


def copy_scratch_tree(src: str, dest: str) -> None:
    if os.path.exists(dest):
        raise ValueError(f"destination already exists: {dest} (pass a fresh scratch directory)")
    src_abs = os.path.abspath(src)
    dest_abs = os.path.abspath(dest)
    if dest_abs == src_abs or dest_abs.startswith(src_abs + os.sep):
        raise ValueError("destination must be outside the source tree")

    def ignore(_dir: str, names: list[str]) -> set[str]:
        return {n for n in names if n in (".git", ".build", "target")}

    shutil.copytree(src_abs, dest_abs, symlinks=True, ignore=ignore)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build or verify a measurement-only CAN_LOCK-off scratch copy of cndf-rdp."
    )
    parser.add_argument("--src", help="Source cndf-rdp tree (e.g. int-13 checkout)")
    parser.add_argument("--dest", help="Fresh scratch output directory (outside --src)")
    parser.add_argument("--dry-run", action="store_true", help="Print unified diff without writing files")
    parser.add_argument("--check", help="Verify that a tree has CAN_LOCK stripped from both engines")
    args = parser.parse_args(argv)

    if args.check:
        problems = check_tree(args.check)
        if problems:
            for p in problems:
                print(f"can-lock-off check FAIL: {p}", file=sys.stderr)
            return 1
        print(f"can-lock-off check OK: {args.check}")
        return 0

    if not args.src:
        print("can-lock-off: --src is required (or use --check <dir>)", file=sys.stderr)
        return 2
    if not args.dry_run and not args.dest:
        print("can-lock-off: --dest is required unless --dry-run is set", file=sys.stderr)
        return 2

    rust_src = os.path.join(args.src, RUST_REL)
    c_src = os.path.join(args.src, C_REL)
    for path in (rust_src, c_src):
        if not os.path.isfile(path):
            print(f"can-lock-off: missing {path}", file=sys.stderr)
            return 1

    with open(rust_src, encoding="utf-8") as fh:
        rust_orig = fh.read()
    with open(c_src, encoding="utf-8") as fh:
        c_orig = fh.read()
    try:
        rust_new, rust_count = transform_rust_clipboard(rust_orig)
        c_new, c_count = transform_c_bridge(c_orig)
    except ValueError as exc:
        print(f"can-lock-off: {exc}", file=sys.stderr)
        return 1

    missing = []
    if rust_count == 0:
        missing.append(f"{RUST_REL} (Capabilities::CAN_LOCK_CLIPDATA not present)")
    if c_count == 0:
        missing.append(f"{C_REL} (CB_CAN_LOCK_CLIPDATA not present)")
    if missing:
        print(
            "can-lock-off: refusing to proceed; CAN_LOCK not found in:\n  - "
            + "\n  - ".join(missing),
            file=sys.stderr,
        )
        return 1

    rust_diff = "".join(
        difflib.unified_diff(
            rust_orig.splitlines(keepends=True),
            rust_new.splitlines(keepends=True),
            fromfile=f"a/{RUST_REL}",
            tofile=f"b/{RUST_REL}",
        )
    )
    c_diff = "".join(
        difflib.unified_diff(
            c_orig.splitlines(keepends=True),
            c_new.splitlines(keepends=True),
            fromfile=f"a/{C_REL}",
            tofile=f"b/{C_REL}",
        )
    )

    if args.dry_run:
        sys.stdout.write(rust_diff)
        sys.stdout.write(c_diff)
        return 0

    try:
        copy_scratch_tree(args.src, args.dest)
    except ValueError as exc:
        print(f"can-lock-off: {exc}", file=sys.stderr)
        return 2

    with open(os.path.join(args.dest, RUST_REL), "w", encoding="utf-8") as fh:
        fh.write(rust_new)
    with open(os.path.join(args.dest, C_REL), "w", encoding="utf-8") as fh:
        fh.write(c_new)
    with open(os.path.join(args.dest, SENTINEL), "w", encoding="utf-8") as fh:
        fh.write("Measurement-only CAN_LOCK-off scratch build (L-W4). Do not commit or tag.\n")

    problems = check_tree(args.dest)
    if problems:
        print("can-lock-off: post-check failed: " + "; ".join(problems), file=sys.stderr)
        return 1

    print(f"can-lock-off: created scratch tree at {args.dest} (removed {rust_count} Rust + {c_count} C flag)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
