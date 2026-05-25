#!/usr/bin/env python3
"""bridge-form-fields-to-natives.py

Parse a GitHub issue body for `### <Label>\\n\\n<value>` sections produced
by issue-form templates, look up the corresponding org-level Issue field
in the `coo-labs` organization, and call `setIssueFieldValue` to populate
the native field.

Invoked from `.github/workflows/bridge-form-fields-to-natives.yml`
(reusable workflow in vade-runtime) on `issues.opened` events in
caller repos. Stage 2 of the issue-fields-and-types migration
(MEMO-2026-05-21-xfqh + vade-coo-memory#811).

Inputs (env):
    GH_TOKEN          PAT with org-level Issue field admin scope.
    REPO_FULL_NAME    e.g. "coo-labs/vade-coo-memory".
    ISSUE_NUMBER      Numeric issue number.
    DRY_RUN           If "1", print intended mutations without applying.

Exit codes:
    0 — success (mutations applied, or nothing to do)
    1 — fatal error (token missing, issue not found, GraphQL failure)

The script is intentionally fail-loud rather than fail-silent: when an
option name in the body doesn't match any field option, it logs the
mismatch and continues (the other matched sections still apply).
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime
from typing import Any

ORG = "coo-labs"
GRAPHQL_URL = "https://api.github.com/graphql"
REST_BASE = "https://api.github.com"


def env(name: str, *, required: bool = True, default: str | None = None) -> str:
    val = os.environ.get(name, default)
    if required and not val:
        sys.stderr.write(f"[bridge] missing required env: {name}\n")
        sys.exit(1)
    return val or ""


def gh_rest(path: str) -> dict[str, Any]:
    req = urllib.request.Request(
        f"{REST_BASE}/{path.lstrip('/')}",
        headers={
            "Authorization": f"Bearer {GH_TOKEN}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def gh_graphql(query: str, variables: dict[str, Any] | None = None) -> dict[str, Any]:
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(
        GRAPHQL_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {GH_TOKEN}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req) as r:
        result = json.loads(r.read())
    if result.get("errors"):
        sys.stderr.write(f"[bridge] graphql errors: {json.dumps(result['errors'])}\n")
        sys.exit(1)
    return result["data"]


def parse_body(body: str) -> dict[str, str]:
    """Parse issue-form-rendered body into {label: value} sections.

    Issue forms render each non-markdown widget as:
        ### <Label>

        <value>

    Multi-line textareas get multi-line values. Unfilled widgets render
    `_No response_`, which we skip.
    """
    if not body:
        return {}
    sections: dict[str, str] = {}
    pattern = re.compile(r"^### (.+?)$\n+(.*?)(?=\n### |\Z)", re.M | re.S)
    for match in pattern.finditer(body):
        label = match.group(1).strip()
        value = match.group(2).strip()
        if value in ("_No response_", "", "_No response_."):
            continue
        sections[label] = value
    return sections


def fetch_org_fields() -> dict[str, dict[str, Any]]:
    """Fetch all org-level Issue fields, return name -> spec dict."""
    query = """
    query($org: String!) {
      organization(login: $org) {
        issueFields(first: 50) {
          nodes {
            ... on IssueFieldSingleSelect {
              id
              name
              dataType
              options { id name }
            }
            ... on IssueFieldText {
              id
              name
              dataType
            }
            ... on IssueFieldDate {
              id
              name
              dataType
            }
            ... on IssueFieldNumber {
              id
              name
              dataType
            }
          }
        }
      }
    }
    """
    data = gh_graphql(query, {"org": ORG})
    nodes = data["organization"]["issueFields"]["nodes"]
    fields: dict[str, dict[str, Any]] = {}
    for node in nodes:
        if not node or "name" not in node:
            continue
        spec = {
            "id": node["id"],
            "dataType": node["dataType"],
        }
        if node["dataType"] == "SINGLE_SELECT":
            spec["options"] = {opt["name"]: opt["id"] for opt in node.get("options", [])}
        fields[node["name"]] = spec
    return fields


def resolve_mutation_inputs(
    sections: dict[str, str], fields: dict[str, dict[str, Any]]
) -> list[dict[str, Any]]:
    """Map parsed body sections to setIssueFieldValue input shapes.

    Returns a list of IssueFieldCreateOrUpdateInput dicts ready to pass
    as the `issueFields` array argument.
    """
    inputs: list[dict[str, Any]] = []
    for label, value in sections.items():
        field = fields.get(label)
        if not field:
            continue  # body section is content, not a native-field bridge
        field_id = field["id"]
        dtype = field["dataType"]
        if dtype == "SINGLE_SELECT":
            option_id = field["options"].get(value) or field["options"].get(value.split("\n", 1)[0].strip())
            if not option_id:
                sys.stderr.write(
                    f"[bridge] {label}: value {value!r} not in options "
                    f"{list(field['options'])} — skipping\n"
                )
                continue
            inputs.append({"fieldId": field_id, "singleSelectOptionId": option_id})
        elif dtype == "TEXT":
            inputs.append({"fieldId": field_id, "textValue": value})
        elif dtype == "DATE":
            try:
                datetime.strptime(value, "%Y-%m-%d")
            except ValueError:
                sys.stderr.write(
                    f"[bridge] {label}: {value!r} not YYYY-MM-DD — skipping\n"
                )
                continue
            inputs.append({"fieldId": field_id, "dateValue": value})
        elif dtype == "NUMBER":
            try:
                num = float(value)
            except ValueError:
                sys.stderr.write(
                    f"[bridge] {label}: {value!r} not numeric — skipping\n"
                )
                continue
            inputs.append({"fieldId": field_id, "numberValue": num})
    return inputs


def apply_mutations(issue_node_id: str, mutation_inputs: list[dict[str, Any]]) -> None:
    """Call setIssueFieldValue once with the full list of field updates."""
    if not mutation_inputs:
        print("[bridge] no native-field sections matched — nothing to apply")
        return
    mutation = """
    mutation($input: SetIssueFieldValueInput!) {
      setIssueFieldValue(input: $input) {
        issue { id number }
      }
    }
    """
    variables = {
        "input": {
            "issueId": issue_node_id,
            "issueFields": mutation_inputs,
        }
    }
    if DRY_RUN:
        print(f"[bridge] DRY_RUN — would set {len(mutation_inputs)} fields:")
        print(json.dumps(mutation_inputs, indent=2))
        return
    gh_graphql(mutation, variables)
    print(f"[bridge] set {len(mutation_inputs)} field values on issue {issue_node_id}")


def main() -> int:
    repo = env("REPO_FULL_NAME")
    issue_number = env("ISSUE_NUMBER")
    owner, name = repo.split("/", 1)

    issue = gh_rest(f"repos/{owner}/{name}/issues/{issue_number}")
    body = issue.get("body") or ""
    issue_node_id = issue["node_id"]

    sections = parse_body(body)
    if not sections:
        print("[bridge] no parseable form sections in body — exiting")
        return 0

    fields = fetch_org_fields()
    mutation_inputs = resolve_mutation_inputs(sections, fields)
    apply_mutations(issue_node_id, mutation_inputs)
    return 0


if __name__ == "__main__":
    GH_TOKEN = env("GH_TOKEN")
    DRY_RUN = os.environ.get("DRY_RUN") == "1"
    try:
        sys.exit(main())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        sys.stderr.write(f"[bridge] HTTP {e.code}: {body}\n")
        sys.exit(1)
