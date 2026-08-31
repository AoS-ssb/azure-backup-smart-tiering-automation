#!/usr/bin/env python3
"""Reject private Azure identifiers and credential material in public files.

Only filenames and rule names are reported. Matched values are never printed,
so CI logs cannot become a second disclosure surface. The checker uses only
the Python standard library and scans tracked plus non-ignored candidate files.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# This repository needs no real GUID in source. These two values are explicit,
# synthetic fixture conventions. Commit IDs and SHA-256 hashes do not match the
# hyphenated GUID grammar and therefore remain publishable.
PUBLIC_GUIDS = {
    "00000000-0000-0000-0000-000000000000",
    "11111111-1111-1111-1111-111111111111",
}

GUID_RE = re.compile(
    r"(?i)(?<![0-9a-f])"
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    r"(?![0-9a-f])"
)
ARM_TENANT_SCOPE_RE = re.compile(
    r"(?i)/(?:subscriptions|tenants)/"
    r"(?P<guid>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
    r"[0-9a-f]{4}-[0-9a-f]{12})(?:/|\b)"
)
EMAIL_RE = re.compile(
    r"(?i)(?<![A-Z0-9._%+-])"
    r"[A-Z0-9._%+-]+@(?P<domain>[A-Z0-9.-]+\.[A-Z]{2,})"
)
ALLOWED_EMAIL_DOMAINS = {
    "example.com",
    "example.net",
    "example.org",
    "users.noreply.github.com",
}

POSIX_HOME_RE = re.compile(
    r"(?<![A-Za-z0-9])(?:/home/|/Users/)"
    r"(?!(?:runner|site|vsts)(?:/|\b))[A-Za-z0-9._-]+"
)
WINDOWS_HOME_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9])[A-Z]:[\\/]Users[\\/]"
    r"(?!(?:runner|vsts)(?:[\\/]|\b))[^\\/\s]+"
)
# Split this literal so the checker does not identify its own rule definition.
ROOT_HOME_RE = re.compile(r"(?<![A-Za-z0-9])/" + r"root(?:/|\b)")

PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
)
GITHUB_TOKEN_RE = re.compile(
    r"(?i)(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"
)
JWT_RE = re.compile(
    r"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\."
    r"[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
)
STORAGE_SECRET_RE = re.compile(
    r"(?i)\b(?:AccountKey|SharedAccessSignature)\s*=\s*"
    r"(?P<value>[^;\s\"']+)"
)
SAS_SIGNATURE_RE = re.compile(
    r"(?i)(?:[?&]|\b)sig\s*=\s*(?P<value>[A-Za-z0-9%_+\-/]{8,})"
)
SECRET_ASSIGNMENT_RE = re.compile(
    r"(?ix)"
    r"[\"']?(?:client[_-]?secret|azure[_-]?client[_-]?secret|"
    r"arm[_-]?client[_-]?secret|password|passwd|api[_-]?key|"
    r"access[_-]?token|refresh[_-]?token)[\"']?"
    r"\s*[:=]\s*(?P<quote>[\"'])(?P<value>[^\"'\r\n]{8,})(?P=quote)"
)
CLI_SECRET_RE = re.compile(
    r"(?i)--(?:client-secret|password)\s+"
    r"[\"']?(?P<value>[^\s\"']{8,})"
)

PLACEHOLDER_MARKERS = (
    "${",
    "<",
    "example",
    "replace",
    "redacted",
    "dummy",
    "changeme",
    "your_",
    "your-",
    "***",
)


def repository_files() -> list[Path]:
    """Return tracked and non-ignored candidate files without reading .git."""

    result = subprocess.run(
        [
            "git",
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    names = result.stdout.decode("utf-8", errors="strict").split("\0")
    return sorted(ROOT / name for name in names if name)


def path_rules(relative: Path) -> set[str]:
    rules: set[str] = set()
    parts = tuple(part.lower() for part in relative.parts)
    name = relative.name.lower()
    posix = relative.as_posix().lower()

    if name.startswith(".env") and name != ".env.example":
        rules.add("private-environment-file")
    if any(part in {".private", ".generated", ".azure"} for part in parts):
        rules.add("private-artifact-path")
    if "/evidence/raw/" in f"/{posix}/" or "raw-evidence" in parts:
        rules.add("raw-evidence-path")
    if name.endswith((".har", ".cast")):
        rules.add("raw-session-capture")
    if name.endswith(".tfstate") or ".tfstate." in name:
        rules.add("terraform-state")
    if name.endswith((".pfx", ".p12", ".key")):
        rules.add("private-key-artifact")
    if name.endswith((".orig", ".bak", ".swp", ".swo", ".rej")) or name.endswith("~"):
        rules.add("editor-backup-artifact")
    return rules


def is_placeholder(value: str) -> bool:
    normalized = value.lower()
    return value.startswith("$") or normalized.startswith(
        ("mock-", "test-", "fixture-")
    ) or any(
        marker in normalized for marker in PLACEHOLDER_MARKERS
    )


def credential_rules(text: str) -> set[str]:
    rules: set[str] = set()
    if PRIVATE_KEY_RE.search(text):
        rules.add("private-key-material")
    if GITHUB_TOKEN_RE.search(text) or JWT_RE.search(text):
        rules.add("token-material")

    for regex in (
        STORAGE_SECRET_RE,
        SAS_SIGNATURE_RE,
        SECRET_ASSIGNMENT_RE,
        CLI_SECRET_RE,
    ):
        for match in regex.finditer(text):
            if not is_placeholder(match.group("value")):
                rules.add("credential-material")
                break
    return rules


def content_rules(text: str) -> set[str]:
    rules: set[str] = set()

    for match in ARM_TENANT_SCOPE_RE.finditer(text):
        if match.group("guid").lower() not in PUBLIC_GUIDS:
            rules.add("tenant-arm-guid-path")

    if any(
        match.group(0).lower() not in PUBLIC_GUIDS
        for match in GUID_RE.finditer(text)
    ):
        rules.add("unapproved-guid")

    for match in EMAIL_RE.finditer(text):
        if match.group("domain").lower() not in ALLOWED_EMAIL_DOMAINS:
            rules.add("non-example-email")
            break

    if (
        POSIX_HOME_RE.search(text)
        or WINDOWS_HOME_RE.search(text)
        or ROOT_HOME_RE.search(text)
    ):
        rules.add("personal-home-path")

    rules.update(credential_rules(text))
    return rules


def main() -> int:
    findings: set[tuple[str, str]] = set()
    try:
        paths = repository_files()
    except (OSError, subprocess.CalledProcessError, UnicodeDecodeError):
        print(".: repository-enumeration-error", file=sys.stderr)
        return 1

    for path in paths:
        relative = path.relative_to(ROOT)
        for rule in path_rules(relative):
            findings.add((relative.as_posix(), rule))

        if path.is_symlink():
            findings.add((relative.as_posix(), "symlinked-public-file"))
            continue
        try:
            data = path.read_bytes()
            if b"\0" in data:
                findings.add((relative.as_posix(), "binary-public-file"))
                continue
            text = data.decode("utf-8")
        except (OSError, UnicodeDecodeError):
            findings.add((relative.as_posix(), "unreadable-or-non-utf8-file"))
            continue

        for rule in content_rules(text):
            findings.add((relative.as_posix(), rule))

    if findings:
        print("Public-content privacy check failed:", file=sys.stderr)
        for filename, rule in sorted(findings):
            print(f"  {filename}: {rule}", file=sys.stderr)
        return 1

    print("Public-content privacy check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
