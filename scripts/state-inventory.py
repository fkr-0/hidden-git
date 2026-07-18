#!/usr/bin/env python3
"""Produce a secret-safe inventory of one or more Soft Serve SQLite databases."""

from __future__ import annotations

import argparse
import json
import sqlite3
from pathlib import Path
from typing import Any


def table_count(connection: sqlite3.Connection, table: str) -> int:
    row = connection.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()
    return int(row[0]) if row else 0


def inventory_database(label: str, path: Path) -> dict[str, Any]:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        tables = [
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
        ]
        counts = {table: table_count(connection, table) for table in tables}

        repositories: list[dict[str, Any]] = []
        if "repos" in tables:
            rows = connection.execute(
                """
                SELECT name, project_name, private, mirror, hidden, created_at, updated_at
                FROM repos
                ORDER BY name
                """
            )
            repositories = [
                {
                    "name": row[0],
                    "project_name": row[1],
                    "private": bool(row[2]),
                    "mirror": bool(row[3]),
                    "hidden": bool(row[4]),
                    "created_at": row[5],
                    "updated_at": row[6],
                }
                for row in rows
            ]

        users: list[dict[str, Any]] = []
        if "users" in tables:
            rows = connection.execute(
                "SELECT username, admin, created_at, updated_at FROM users ORDER BY username"
            )
            users = [
                {
                    "username": row[0],
                    "admin": bool(row[1]),
                    "created_at": row[2],
                    "updated_at": row[3],
                }
                for row in rows
            ]

        return {
            "label": label,
            "tables": counts,
            "repository_count": len(repositories),
            "repositories": repositories,
            "user_count": len(users),
            "users": users,
        }
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "database",
        nargs="+",
        metavar="LABEL=PATH",
        help="database to inventory, for example current=/tmp/current.db",
    )
    args = parser.parse_args()

    result: dict[str, Any] = {"schema_version": 1, "deployments": {}}
    for item in args.database:
        if "=" not in item:
            parser.error(f"invalid database argument: {item}")
        label, raw_path = item.split("=", 1)
        path = Path(raw_path)
        if not path.is_file():
            parser.error(f"database does not exist: {path}")
        result["deployments"][label] = inventory_database(label, path)

    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
