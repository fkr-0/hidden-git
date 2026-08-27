#!/usr/bin/env python3
"""HiddenGit environment schema validation and idempotent migration.

This tool intentionally never evaluates shell syntax. It accepts the subset of
.env syntax used by HiddenGit: comments, blank lines, KEY=VALUE assignments,
single/double-quoted values, and whitespace-delimited inline comments.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
from datetime import datetime, timezone
from typing import Any
from urllib.parse import urlparse

ASSIGNMENT_RE = re.compile(r"^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=(.*)$")
SEMVER_RE = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
VERSION_TAG_RE = re.compile(r"^v[0-9]+(?:\.[0-9]+){0,2}(?:[-+][0-9A-Za-z.-]+)?$")
IMAGE_DIGEST_RE = re.compile(r"^.+@sha256:[0-9a-f]{64}$")
SIMPLE_VALUE_RE = re.compile(r"^[A-Za-z0-9_./:@%+,=-]+$")


class ConfigError(Exception):
    pass


def split_value(raw: str, *, line_no: int) -> str:
    value = raw.strip()
    if not value:
        return ""

    if value[0] in "'\"":
        quote = value[0]
        escaped = False
        chars: list[str] = []
        closing = None
        for index, char in enumerate(value[1:], start=1):
            if quote == '"' and escaped:
                chars.append(char)
                escaped = False
                continue
            if quote == '"' and char == "\\":
                escaped = True
                chars.append(char)
                continue
            if char == quote:
                closing = index
                break
            chars.append(char)
        if closing is None:
            raise ConfigError(f"line {line_no}: unterminated quoted value")
        tail = value[closing + 1 :].strip()
        if tail and not tail.startswith("#"):
            raise ConfigError(f"line {line_no}: unexpected content after quoted value")
        inner = "".join(chars)
        if quote == '"':
            inner = inner.replace('\\"', '"').replace('\\\\', '\\')
        return inner

    # A # starts an inline comment only when preceded by whitespace. Literal #
    # characters inside URLs/tokens are therefore preserved.
    for match in re.finditer(r"[ \t]+#", value):
        value = value[: match.start()].rstrip()
        break
    return value.rstrip()


def parse_env(path: Path) -> tuple[dict[str, str], dict[str, int]]:
    if not path.is_file():
        raise ConfigError(f"environment file not found: {path}")
    values: dict[str, str] = {}
    lines: dict[str, int] = {}
    for line_no, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = ASSIGNMENT_RE.match(raw_line)
        if not match:
            raise ConfigError(f"line {line_no}: expected KEY=VALUE assignment")
        key = match.group(1)
        if key in values:
            raise ConfigError(f"line {line_no}: duplicate key {key} (first seen on line {lines[key]})")
        values[key] = split_value(match.group(2), line_no=line_no)
        lines[key] = line_no
    return values, lines


def load_schema(path: Path) -> dict[str, Any]:
    try:
        schema = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"cannot load schema {path}: {exc}") from exc
    if schema.get("schema_version") != 1:
        raise ConfigError(f"unsupported schema document version: {schema.get('schema_version')!r}")
    return schema


def validate_typed_value(key: str, value: str, type_name: str, spec: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if type_name == "optional":
        return errors
    if type_name == "const":
        if value != str(spec["value"]):
            errors.append(f"{key} must equal {spec['value']}")
    elif type_name == "nonempty":
        if not value:
            errors.append(f"{key} must not be empty")
    elif type_name == "port":
        if not value.isdigit() or not (1 <= int(value) <= 65535):
            errors.append(f"{key} must be an integer between 1 and 65535")
    elif type_name == "positive-integer":
        if not value.isdigit() or int(value) < 1:
            errors.append(f"{key} must be a positive integer")
    elif type_name == "semver":
        if not SEMVER_RE.fullmatch(value):
            errors.append(f"{key} must be valid Semantic Versioning")
    elif type_name == "version-tag":
        if not VERSION_TAG_RE.fullmatch(value):
            errors.append(f"{key} must be a v-prefixed version tag")
    elif type_name == "image-digest":
        if not IMAGE_DIGEST_RE.fullmatch(value):
            errors.append(f"{key} must be pinned by an sha256 OCI digest")
    elif type_name == "bind-address":
        if not value or any(ch.isspace() for ch in value) or "/" in value:
            errors.append(f"{key} must be a host bind address without whitespace or CIDR syntax")
    elif type_name == "optional-ssh-url":
        if value:
            parsed = urlparse(value)
            if parsed.scheme != "ssh" or not parsed.hostname:
                errors.append(f"{key} must be empty or an ssh:// URL with a hostname")
            elif parsed.port is not None and not (1 <= parsed.port <= 65535):
                errors.append(f"{key} contains an invalid port")
    else:
        errors.append(f"{key} uses unknown schema type {type_name}")
    return errors


def validate_current(
    values: dict[str, str], schema: dict[str, Any], template_values: dict[str, str]
) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    specs: dict[str, dict[str, Any]] = schema["keys"]
    legacy = schema["legacy_keys"]

    for key in values:
        if key in legacy:
            errors.append(f"legacy key {key} requires migration")
        elif key not in specs:
            errors.append(f"unknown key {key}")

    for key, spec in specs.items():
        if spec.get("required") and key not in values:
            errors.append(f"missing required key {key}")
            continue
        if key in values:
            errors.extend(validate_typed_value(key, values[key], spec["type"], spec))
            if spec.get("kind") == "release-managed" and key in template_values:
                if values[key] != template_values[key]:
                    errors.append(f"release-managed key {key} differs from this checkout; run './run.sh sync-pins'")

    return errors, warnings


def quote_env(value: str) -> str:
    if value == "":
        return ""
    if SIMPLE_VALUE_RE.fullmatch(value) and "#" not in value:
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def render_template(template: Path, values: dict[str, str]) -> bytes:
    output: list[str] = []
    for line_no, line in enumerate(template.read_text(encoding="utf-8").splitlines(), start=1):
        match = ASSIGNMENT_RE.match(line)
        if not match:
            output.append(line)
            continue
        key = match.group(1)
        if key not in values:
            raise ConfigError(f"template line {line_no}: key {key} missing from migration result")
        output.append(f"{key}={quote_env(values[key])}")
    return ("\n".join(output) + "\n").encode("utf-8")


def redacted_value(key: str, value: str, schema: dict[str, Any]) -> str:
    spec = schema["keys"].get(key, {})
    if spec.get("secret"):
        return "<redacted>" if value else "<empty>"
    return value if value else "<empty>"


def migrate_values(
    values: dict[str, str], schema: dict[str, Any], template_values: dict[str, str]
) -> tuple[dict[str, str], list[str]]:
    specs: dict[str, dict[str, Any]] = schema["keys"]
    legacy_specs: dict[str, dict[str, str]] = schema["legacy_keys"]
    warnings: list[str] = []

    unknown = sorted(set(values) - set(specs) - set(legacy_specs))
    if unknown:
        raise ConfigError("unknown key(s) block migration: " + ", ".join(unknown))

    # Start from the exact current release template so every required key and
    # release-managed pin converges to the checkout being installed.
    result = dict(template_values)

    # Preserve current-schema deployment intent. Release-managed fields are
    # deliberately not preserved: migration upgrades them to reviewed values.
    for key, value in values.items():
        if key in specs and specs[key].get("kind") != "release-managed":
            result[key] = value

    old_ssh = values.get("SOFT_SERVE_SSH_PORT")
    old_target = values.get("ONION_TARGET_PORT")
    if old_ssh:
        if not old_ssh.isdigit() or not (1 <= int(old_ssh) <= 65535):
            raise ConfigError("legacy SOFT_SERVE_SSH_PORT is invalid")
        if "LOCAL_SSH_PORT" in values and values["LOCAL_SSH_PORT"] != old_ssh:
            raise ConfigError("LOCAL_SSH_PORT conflicts with legacy SOFT_SERVE_SSH_PORT")
        result["LOCAL_SSH_PORT"] = old_ssh
        if old_target and old_target != old_ssh:
            raise ConfigError("legacy ONION_TARGET_PORT does not match SOFT_SERVE_SSH_PORT")
    elif old_target and old_target != legacy_specs["ONION_TARGET_PORT"]["default"]:
        raise ConfigError("legacy ONION_TARGET_PORT has no matching SOFT_SERVE_SSH_PORT")

    # If the old public URL was merely the generated localhost default, allow
    # the new runtime to derive it from LOCAL_SSH_PORT. Custom public endpoints
    # remain explicit advanced overrides.
    old_ssh_url = values.get("SOFT_SERVE_SSH_PUBLIC_URL")
    if old_ssh_url and old_ssh:
        if old_ssh_url == f"ssh://localhost:{old_ssh}":
            result["SOFT_SERVE_SSH_PUBLIC_URL"] = ""

    for key in ("SOFT_SERVE_DATA_PATH", "CI"):
        if key in values and values[key] != legacy_specs[key]["default"]:
            raise ConfigError(
                f"legacy {key}={values[key]!r} changes an internal invariant; migrate that topology manually"
            )

    for key in ("SOFT_SERVE_HTTP_PORT", "SOFT_SERVE_STATS_PORT", "SOFT_SERVE_GIT_PORT"):
        if key in values and values[key] != legacy_specs[key]["default"]:
            warnings.append(
                f"{key}={values[key]} is retired: auxiliary listeners are no longer host-published; "
                "use a reviewed Compose override if local access is still required"
            )

    for key in ("SOFT_SERVE_HTTP_PUBLIC_URL", "SOFT_SERVE_GIT_PUBLIC_URL"):
        if key in values and values[key] and values[key] != legacy_specs[key]["default"]:
            warnings.append(f"{key} is retired because its service is disabled in the default HiddenGit profile")

    # Current schema version is always authoritative after migration.
    result[schema["config_version_key"]] = str(schema["current_config_version"])
    return result, warnings


def mode_is_private(path: Path) -> bool:
    mode = stat.S_IMODE(path.stat().st_mode)
    return mode & 0o077 == 0


def diff_keys(
    before: dict[str, str], after: dict[str, str], schema: dict[str, Any]
) -> tuple[list[dict[str, str]], list[str], list[str]]:
    changed: list[dict[str, str]] = []
    added = sorted(set(after) - set(before))
    removed = sorted(set(before) - set(after))
    for key in sorted(set(before) & set(after)):
        if before[key] != after[key]:
            changed.append(
                {
                    "key": key,
                    "before": redacted_value(key, before[key], schema),
                    "after": redacted_value(key, after[key], schema),
                }
            )
    return changed, added, removed


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.migrate-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
        dir_fd = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def make_backup(path: Path) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    base = path.with_name(f"{path.name}.pre-config-{stamp}")
    backup = base
    suffix = 1
    while backup.exists():
        backup = path.with_name(f"{base.name}.{suffix}")
        suffix += 1
    shutil.copy2(path, backup)
    os.chmod(backup, 0o600)
    return backup


def emit_check(errors: list[str], warnings: list[str], *, json_mode: bool) -> int:
    if json_mode:
        print(json.dumps({"valid": not errors, "errors": errors, "warnings": warnings}, indent=2, sort_keys=True))
    else:
        for warning in warnings:
            print(f"WARN: {warning}")
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        if not errors:
            print("Configuration schema: valid")
    return 0 if not errors else 2


def cmd_check(args: argparse.Namespace) -> int:
    schema = load_schema(args.schema)
    try:
        values, _ = parse_env(args.env)
        template_values, _ = parse_env(args.template)
        errors, warnings = validate_current(values, schema, template_values)
        if not mode_is_private(args.env):
            errors.append(f"{args.env} must not be readable by group or others (expected mode 0600 or stricter)")
    except (ConfigError, OSError) as exc:
        errors = [str(exc)]
        warnings = []
    return emit_check(errors, warnings, json_mode=args.json)


def cmd_migrate(args: argparse.Namespace) -> int:
    schema = load_schema(args.schema)
    try:
        before, _ = parse_env(args.env)
        template_values, _ = parse_env(args.template)
        after, warnings = migrate_values(before, schema, template_values)
        rendered = render_template(args.template, after)
        current_bytes = args.env.read_bytes()
        content_changed = rendered != current_bytes
        mode_changed = not mode_is_private(args.env)
        changed, added, removed = diff_keys(before, after, schema)
        plan: dict[str, Any] = {
            "changed": content_changed or mode_changed,
            "content_changed": content_changed,
            "mode_changed": mode_changed,
            "changes": changed,
            "added": added,
            "removed": removed,
            "warnings": warnings,
            "backup": None,
            "applied": False,
        }
        if args.apply and plan["changed"]:
            backup = make_backup(args.env)
            if content_changed:
                atomic_write(args.env, rendered)
            else:
                os.chmod(args.env, 0o600)
            # atomic_write already forces 0600; this also covers only-mode fixes.
            os.chmod(args.env, 0o600)
            plan["backup"] = str(backup)
            plan["applied"] = True
        elif args.apply:
            plan["applied"] = False

        if args.json:
            print(json.dumps(plan, indent=2, sort_keys=True))
        else:
            status = "changes required" if plan["changed"] else "already canonical"
            print(f"Configuration migration: {status}")
            for item in changed:
                print(f"  change {item['key']}: {item['before']} -> {item['after']}")
            for key in added:
                print(f"  add {key}")
            for key in removed:
                print(f"  remove {key}")
            if mode_changed:
                print("  restrict file mode to 0600")
            for warning in warnings:
                print(f"WARN: {warning}")
            if args.apply and plan["changed"]:
                print(f"Applied migration; rollback copy: {plan['backup']}")
            elif args.apply:
                print("No changes applied; no rollback copy created")
            else:
                print("Preview only; rerun with --apply to write the migration")
        return 0
    except (ConfigError, OSError, ValueError) as exc:
        if args.json:
            print(json.dumps({"changed": False, "applied": False, "error": str(exc)}, indent=2, sort_keys=True))
        else:
            print(f"ERROR: {exc}", file=sys.stderr)
        return 2


def parser() -> argparse.ArgumentParser:
    root = Path(__file__).resolve().parent.parent
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--env", type=Path, default=root / ".env")
    result.add_argument("--schema", type=Path, default=root / "config/schema.json")
    result.add_argument("--template", type=Path, default=root / "env.example")
    sub = result.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="validate the current schema without mutation")
    check.add_argument("--json", action="store_true")
    check.set_defaults(func=cmd_check)

    migrate = sub.add_parser("migrate", help="preview or apply deterministic migration to the current schema")
    migrate.add_argument("--apply", action="store_true")
    migrate.add_argument("--json", action="store_true")
    migrate.set_defaults(func=cmd_migrate)
    return result


def main() -> int:
    args = parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
