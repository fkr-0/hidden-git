#!/usr/bin/env python3
"""HiddenGit configuration validation, value access, and safe migration.

This is the single parser boundary for both operator configuration and tracked
release metadata. It never evaluates shell syntax. Supported .env syntax is
limited to comments, blank lines, KEY=VALUE assignments, quoted values, and
whitespace-delimited inline comments.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
from typing import Any
from urllib.parse import urlparse

ASSIGNMENT_RE = re.compile(r"^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=(.*)$")
VERSION_TAG_RE = re.compile(r"^v[0-9]+(?:\.[0-9]+){0,2}(?:[-+][0-9A-Za-z.-]+)?$")
IMAGE_DIGEST_RE = re.compile(r"^.+@sha256:[0-9a-f]{64}$")
SIMPLE_VALUE_RE = re.compile(r"^[A-Za-z0-9_./:@%+,=-]+$")
RETIRED_V1_RELEASE_OVERRIDE_KEYS = {
    "SOFT_SERVE_WISH_VERSION",
    "SOFT_SERVE_GO_GIT_VERSION",
    "SOFT_SERVE_GO_JOSE_VERSION",
    "SOFT_SERVE_X_CRYPTO_VERSION",
    "SOFT_SERVE_X_NET_VERSION",
}
RETIRED_AUXILIARY_KEYS = (
    "SOFT_SERVE_HTTP_PORT",
    "SOFT_SERVE_STATS_PORT",
    "SOFT_SERVE_GIT_PORT",
    "SOFT_SERVE_HTTP_PUBLIC_URL",
    "SOFT_SERVE_GIT_PUBLIC_URL",
)


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
                if char not in {'"', "\\"}:
                    raise ConfigError(
                        f"line {line_no}: unsupported double-quoted escape \\{char}; "
                        "use single quotes for literal backslashes"
                    )
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
        if escaped:
            raise ConfigError(f"line {line_no}: unterminated escape in quoted value")
        tail = value[closing + 1 :].strip()
        if tail and not tail.startswith("#"):
            raise ConfigError(f"line {line_no}: unexpected content after quoted value")
        inner = "".join(chars)
        if quote == '"':
            inner = inner.replace('\\"', '"').replace('\\\\', '\\')
        return inner

    # A # begins an inline comment only after whitespace; literal URL/token '#'
    # characters are retained.
    for match in re.finditer(r"[ \t]+#", value):
        value = value[: match.start()].rstrip()
        break
    return value.rstrip()


def parse_env(path: Path) -> tuple[dict[str, str], dict[str, int]]:
    if not path.is_file():
        raise ConfigError(f"configuration file not found: {path}")
    values: dict[str, str] = {}
    lines: dict[str, int] = {}
    try:
        content = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise ConfigError(f"configuration file is not valid UTF-8: {path}") from exc
    for line_no, raw_line in enumerate(content.splitlines(), start=1):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = ASSIGNMENT_RE.match(raw_line)
        if not match:
            raise ConfigError(f"line {line_no}: expected KEY=VALUE assignment")
        key = match.group(1)
        if key in values:
            raise ConfigError(
                f"line {line_no}: duplicate key {key} (first seen on line {lines[key]})"
            )
        values[key] = split_value(match.group(2), line_no=line_no)
        lines[key] = line_no
    return values, lines


def load_schema(path: Path) -> dict[str, Any]:
    try:
        schema = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"cannot load schema {path}: {exc}") from exc
    if schema.get("schema_version") != 1:
        raise ConfigError(
            f"unsupported schema document version: {schema.get('schema_version')!r}"
        )
    if not isinstance(schema.get("keys"), dict) or not isinstance(
        schema.get("release_keys"), dict
    ):
        raise ConfigError("schema is missing operator or release key definitions")
    return schema


def validate_typed_value(
    key: str, value: str, type_name: str, spec: dict[str, Any]
) -> list[str]:
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
    elif type_name == "version-tag":
        if not VERSION_TAG_RE.fullmatch(value):
            errors.append(f"{key} must be a v-prefixed version tag")
    elif type_name == "image-digest":
        if not IMAGE_DIGEST_RE.fullmatch(value):
            errors.append(f"{key} must be pinned by an sha256 OCI digest")
    elif type_name == "bind-address":
        if not value or any(ch.isspace() for ch in value) or "/" in value:
            errors.append(
                f"{key} must be a host bind address without whitespace or CIDR syntax"
            )
    elif type_name == "optional-ssh-url":
        if value:
            if any(ch.isspace() or ch in {'"', "\\"} for ch in value):
                errors.append(
                    f"{key} must not contain whitespace, double quotes, or backslashes"
                )
            try:
                parsed = urlparse(value)
                port = parsed.port
            except ValueError:
                errors.append(f"{key} contains an invalid port")
            else:
                if parsed.scheme != "ssh" or not parsed.hostname:
                    errors.append(f"{key} must be empty or an ssh:// URL with a hostname")
                elif port is not None and not (1 <= port <= 65535):
                    errors.append(f"{key} contains an invalid port")
    else:
        errors.append(f"{key} uses unknown schema type {type_name}")
    return errors


def validate_current(values: dict[str, str], schema: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    specs: dict[str, dict[str, Any]] = schema["keys"]
    legacy: dict[str, dict[str, Any]] = schema["legacy_keys"]
    for key, value in values.items():
        if "$" in value:
            errors.append(
                f"{key} must not contain '$'; Docker Compose interpolates dollar references"
            )
        if key in legacy and key not in specs:
            errors.append(f"legacy key {key} requires migration")
        elif key not in specs:
            errors.append(f"unknown key {key}")
    for key, spec in specs.items():
        if spec.get("required") and key not in values:
            errors.append(f"missing required key {key}")
            continue
        if key in values:
            errors.extend(validate_typed_value(key, values[key], spec["type"], spec))
    return errors


def validate_release(values: dict[str, str], schema: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    specs: dict[str, dict[str, Any]] = schema["release_keys"]
    for key in values:
        if key not in specs:
            errors.append(f"unknown release key {key}")
    for key, spec in specs.items():
        if spec.get("required") and key not in values:
            errors.append(f"missing required release key {key}")
            continue
        if key in values:
            errors.extend(validate_typed_value(key, values[key], spec["type"], spec))
    return errors


def validated_release(path: Path, schema: dict[str, Any]) -> dict[str, str]:
    values, _ = parse_env(path)
    errors = validate_release(values, schema)
    if errors:
        raise ConfigError("; ".join(errors))
    return values


def validated_template(path: Path, schema: dict[str, Any]) -> dict[str, str]:
    values, _ = parse_env(path)
    errors = validate_current(values, schema)
    if errors:
        raise ConfigError("operator template is invalid: " + "; ".join(errors))
    return values


def quote_env(value: str) -> str:
    if value == "":
        return ""
    if SIMPLE_VALUE_RE.fullmatch(value) and "#" not in value:
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def render_template(template: Path, values: dict[str, str]) -> bytes:
    output: list[str] = []
    for line_no, line in enumerate(
        template.read_text(encoding="utf-8").splitlines(), start=1
    ):
        match = ASSIGNMENT_RE.match(line)
        if not match:
            output.append(line)
            continue
        key = match.group(1)
        if key not in values:
            raise ConfigError(
                f"template line {line_no}: key {key} missing from migration result"
            )
        output.append(f"{key}={quote_env(values[key])}")
    return ("\n".join(output) + "\n").encode("utf-8")


def redacted_value(key: str, value: str, schema: dict[str, Any]) -> str:
    spec = schema["keys"].get(key, {})
    if spec.get("secret"):
        return "<redacted>" if value else "<empty>"
    return value if value else "<empty>"


def validate_legacy_url(key: str, value: str) -> None:
    if value == "":
        return
    try:
        parsed = urlparse(value)
        _ = parsed.port
    except ValueError as exc:
        raise ConfigError(f"legacy {key} is malformed") from exc
    expected = "http" if key == "SOFT_SERVE_HTTP_PUBLIC_URL" else "git"
    allowed = {"http", "https"} if expected == "http" else {"git"}
    if parsed.scheme not in allowed or not parsed.hostname:
        raise ConfigError(f"legacy {key} is malformed")


def validate_legacy_port(key: str, value: str) -> None:
    if not value.isdigit() or not (1 <= int(value) <= 65535):
        raise ConfigError(f"legacy {key} is invalid")


def migrate_legacy_values(
    values: dict[str, str],
    schema: dict[str, Any],
    template_values: dict[str, str],
    *,
    accept_retired_auxiliary_topology: bool,
) -> tuple[dict[str, str], str, list[str], list[str]]:
    specs: dict[str, dict[str, Any]] = schema["keys"]
    legacy_specs: dict[str, dict[str, Any]] = schema["legacy_keys"]
    version_key = schema["config_version_key"]
    current_version = str(schema["current_config_version"])

    unknown = sorted(
        set(values) - set(specs) - set(legacy_specs) - RETIRED_V1_RELEASE_OVERRIDE_KEYS
    )
    if unknown:
        raise ConfigError("unknown key(s) block migration: " + ", ".join(unknown))

    source_version = values.get(version_key)
    if source_version is not None and source_version not in {"1", current_version}:
        if source_version.isdigit() and int(source_version) > int(current_version):
            raise ConfigError(
                f"future configuration version {source_version} is unsupported by this release"
            )
        raise ConfigError(f"unsupported configuration version {source_version!r}")
    if source_version == current_version:
        errors = validate_current(values, schema)
        if errors:
            raise ConfigError("; ".join(errors))
        return dict(values), "CURRENT", [], []

    # Validate every field that already belongs to the target operator schema.
    # The old config-version value is deliberately excluded from the v2 const.
    for key, value in values.items():
        if key in specs and key != version_key:
            typed_errors = validate_typed_value(key, value, specs[key]["type"], specs[key])
            if typed_errors:
                raise ConfigError("; ".join(typed_errors))

    old_ssh = values.get("SOFT_SERVE_SSH_PORT")
    old_target = values.get("ONION_TARGET_PORT")
    if old_ssh is not None:
        validate_legacy_port("SOFT_SERVE_SSH_PORT", old_ssh)
        if "LOCAL_SSH_PORT" in values:
            raise ConfigError(
                "LOCAL_SSH_PORT conflicts with legacy SOFT_SERVE_SSH_PORT; remove one alias before migration"
            )
    if old_target is not None:
        validate_legacy_port("ONION_TARGET_PORT", old_target)
        if old_ssh is not None and old_target != old_ssh:
            raise ConfigError(
                "legacy ONION_TARGET_PORT does not match SOFT_SERVE_SSH_PORT"
            )
        if old_ssh is None and old_target != legacy_specs["ONION_TARGET_PORT"]["default"]:
            raise ConfigError(
                "legacy ONION_TARGET_PORT has no matching SOFT_SERVE_SSH_PORT"
            )

    for key in ("SOFT_SERVE_DATA_PATH", "CI"):
        if key in values and values[key] != legacy_specs[key]["default"]:
            raise ConfigError(
                f"legacy {key} changes an internal invariant; migrate that topology manually"
            )

    for key in (
        "SOFT_SERVE_HTTP_PORT",
        "SOFT_SERVE_STATS_PORT",
        "SOFT_SERVE_GIT_PORT",
    ):
        if key in values:
            validate_legacy_port(key, values[key])
    for key in ("SOFT_SERVE_HTTP_PUBLIC_URL", "SOFT_SERVE_GIT_PUBLIC_URL"):
        if key in values:
            validate_legacy_url(key, values[key])

    lossy_keys = sorted(
        key
        for key in RETIRED_AUXILIARY_KEYS
        if key in values and values[key] != str(legacy_specs[key]["default"])
    )

    result = dict(template_values)
    for key, value in values.items():
        if key in specs and key != version_key:
            result[key] = value
    if old_ssh is not None:
        result["LOCAL_SSH_PORT"] = old_ssh
    result[version_key] = current_version

    result_errors = validate_current(result, schema)
    if result_errors:
        raise ConfigError("migration result is invalid: " + "; ".join(result_errors))

    warnings: list[str] = []
    if lossy_keys:
        warnings.append(
            "retiring non-default auxiliary topology: " + ", ".join(lossy_keys)
        )
        state = (
            "MIGRATABLE_ACK"
            if accept_retired_auxiliary_topology
            else "BLOCKED_LOSSY"
        )
    else:
        state = "MIGRATABLE"
    return result, state, warnings, lossy_keys


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


def fsync_directory(path: Path) -> None:
    dir_fd = os.open(path, os.O_DIRECTORY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


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
        fsync_directory(path.parent)
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
    shutil.copyfile(path, backup)
    os.chmod(backup, 0o600)
    with backup.open("rb") as handle:
        os.fsync(handle.fileno())
    fsync_directory(path.parent)
    return backup


def emit_check(errors: list[str], warnings: list[str], *, json_mode: bool) -> int:
    if json_mode:
        print(
            json.dumps(
                {"valid": not errors, "errors": errors, "warnings": warnings},
                indent=2,
                sort_keys=True,
            )
        )
    else:
        for warning in warnings:
            print(f"WARN: {warning}")
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        if not errors:
            print("Configuration schema and tracked release metadata: valid")
    return 0 if not errors else 2


def cmd_check(args: argparse.Namespace) -> int:
    schema = load_schema(args.schema)
    errors: list[str] = []
    warnings: list[str] = []
    try:
        values, _ = parse_env(args.env)
        validated_template(args.template, schema)
        errors.extend(validate_current(values, schema))
        release_values, _ = parse_env(args.release_file)
        errors.extend(
            f"release metadata: {error}" for error in validate_release(release_values, schema)
        )
        if not args.ignore_mode and not mode_is_private(args.env):
            errors.append(
                f"{args.env} must not be readable by group or others (expected mode 0600 or stricter)"
            )
    except (ConfigError, OSError) as exc:
        errors.append(str(exc))
    return emit_check(errors, warnings, json_mode=args.json)


def require_valid_current(args: argparse.Namespace) -> tuple[dict[str, str], dict[str, Any]]:
    schema = load_schema(args.schema)
    validated_template(args.template, schema)
    validated_release(args.release_file, schema)
    values, _ = parse_env(args.env)
    errors = validate_current(values, schema)
    if errors:
        raise ConfigError("; ".join(errors))
    if not mode_is_private(args.env):
        raise ConfigError(f"{args.env} must have mode 0600 or stricter")
    return values, schema


def cmd_get(args: argparse.Namespace) -> int:
    try:
        values, schema = require_valid_current(args)
        if args.key not in schema["keys"]:
            raise ConfigError(f"unknown operator key {args.key}")
        print(values[args.key])
        return 0
    except (ConfigError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


def cmd_release_check(args: argparse.Namespace) -> int:
    schema = load_schema(args.schema)
    try:
        values, _ = parse_env(args.release_file)
        errors = validate_release(values, schema)
    except (ConfigError, OSError) as exc:
        errors = [str(exc)]
    return emit_check(errors, [], json_mode=args.json)


def cmd_release_get(args: argparse.Namespace) -> int:
    try:
        schema = load_schema(args.schema)
        values = validated_release(args.release_file, schema)
        if args.key not in schema["release_keys"]:
            raise ConfigError(f"unknown release key {args.key}")
        print(values[args.key])
        return 0
    except (ConfigError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


def cmd_migrate(args: argparse.Namespace) -> int:
    schema = load_schema(args.schema)
    try:
        before, _ = parse_env(args.env)
        template_values = validated_template(args.template, schema)
        validated_release(args.release_file, schema)
        after, state, warnings, lossy_keys = migrate_legacy_values(
            before,
            schema,
            template_values,
            accept_retired_auxiliary_topology=args.accept_retired_auxiliary_topology,
        )
        current_bytes = args.env.read_bytes()
        if state == "CURRENT":
            rendered = current_bytes
        else:
            rendered = render_template(args.template, after)
        content_changed = rendered != current_bytes
        mode_changed = not mode_is_private(args.env)
        changed, added, removed = diff_keys(before, after, schema)
        plan: dict[str, Any] = {
            "state": state,
            "changed": content_changed or mode_changed,
            "content_changed": content_changed,
            "mode_changed": mode_changed,
            "changes": changed,
            "added": added,
            "removed": removed,
            "lossy_keys": lossy_keys,
            "warnings": warnings,
            "backup": None,
            "applied": False,
        }

        blocked_apply = args.apply and state == "BLOCKED_LOSSY"
        if blocked_apply:
            if args.json:
                print(json.dumps(plan, indent=2, sort_keys=True))
            else:
                print("Configuration migration: BLOCKED_LOSSY")
                for key in lossy_keys:
                    print(f"  retire {key} (non-default legacy topology)")
                print(
                    "ERROR: migration would retire intentional auxiliary topology; "
                    "prepare any required reviewed extension, then rerun with "
                    "--accept-retired-auxiliary-topology",
                    file=sys.stderr,
                )
            return 2

        if args.apply and plan["changed"]:
            if content_changed:
                backup = make_backup(args.env)
                atomic_write(args.env, rendered)
                plan["backup"] = str(backup)
            os.chmod(args.env, 0o600)
            fsync_directory(args.env.parent)
            plan["applied"] = True

        if args.json:
            print(json.dumps(plan, indent=2, sort_keys=True))
        else:
            print(f"Configuration migration: {state}")
            for item in changed:
                print(
                    f"  change {item['key']}: {item['before']} -> {item['after']}"
                )
            for key in added:
                print(f"  add {key}")
            for key in removed:
                print(f"  remove {key}")
            for key in lossy_keys:
                print(f"  retire {key} (non-default legacy topology)")
            if mode_changed:
                print("  restrict file mode to 0600")
            for warning in warnings:
                print(f"WARN: {warning}")
            if state == "BLOCKED_LOSSY" and not args.apply:
                print(
                    "Preview blocked pending explicit --accept-retired-auxiliary-topology acknowledgement"
                )
            elif args.apply and plan["changed"]:
                print(f"Applied migration; rollback copy: {plan['backup']}")
            elif args.apply:
                print("No changes applied; no rollback copy created")
            else:
                print("Preview only; rerun with --apply to write the migration")
        return 0
    except (ConfigError, OSError, ValueError) as exc:
        if args.json:
            print(
                json.dumps(
                    {
                        "state": "INVALID",
                        "changed": False,
                        "applied": False,
                        "error": str(exc),
                    },
                    indent=2,
                    sort_keys=True,
                )
            )
        else:
            print(f"ERROR: {exc}", file=sys.stderr)
        return 2


def parser() -> argparse.ArgumentParser:
    root = Path(__file__).resolve().parent.parent
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--env", type=Path, default=root / ".env")
    result.add_argument("--schema", type=Path, default=root / "config/schema.json")
    result.add_argument("--template", type=Path, default=root / "env.example")
    result.add_argument(
        "--release-file", type=Path, default=root / "config/release.env"
    )
    sub = result.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="validate current operator and release configuration")
    check.add_argument("--json", action="store_true")
    check.add_argument(
        "--ignore-mode",
        action="store_true",
        help="validate content while allowing a caller to repair file permissions",
    )
    check.set_defaults(func=cmd_check)

    get = sub.add_parser("get", help="read one value after validating the complete current config")
    get.add_argument("key")
    get.set_defaults(func=cmd_get)

    release = sub.add_parser("release", help="validate/read tracked release metadata")
    release_sub = release.add_subparsers(dest="release_command", required=True)
    release_check = release_sub.add_parser("check", help="validate tracked release metadata")
    release_check.add_argument("--json", action="store_true")
    release_check.set_defaults(func=cmd_release_check)
    release_get = release_sub.add_parser("get", help="read one validated tracked release value")
    release_get.add_argument("key")
    release_get.set_defaults(func=cmd_release_get)

    migrate = sub.add_parser(
        "migrate", help="preview or apply deterministic migration to schema v2"
    )
    migrate.add_argument("--apply", action="store_true")
    migrate.add_argument("--json", action="store_true")
    migrate.add_argument(
        "--accept-retired-auxiliary-topology",
        action="store_true",
        help="acknowledge retirement of non-default legacy HTTP/Git/stats topology only",
    )
    migrate.set_defaults(func=cmd_migrate)
    return result


def main() -> int:
    args = parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
