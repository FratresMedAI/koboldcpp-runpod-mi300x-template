#!/usr/bin/env python3
import json
import os
import sys
import urllib.error
import urllib.request
import urllib.parse


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def post_json(url: str, payload: dict, headers: dict) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", **headers},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        body = resp.read().decode("utf-8")
    if not body:
        return {}
    return json.loads(body)


def normalize_runpod_webhook_url(raw_url: str) -> str:
    url = (raw_url or "").strip()
    if not url:
        return ""
    if ".api.runpod.ai" in url and not url.rstrip("/").endswith("/run"):
        return url.rstrip("/") + "/run"
    return url


def add_api_key_query(url: str, api_key: str) -> str:
    if not api_key:
        return url
    parsed = urllib.parse.urlparse(url)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    if "api_key" not in query:
        query["api_key"] = [api_key]
    new_query = urllib.parse.urlencode(query, doseq=True)
    return urllib.parse.urlunparse(parsed._replace(query=new_query))


def trigger_webhook() -> int:
    webhook = normalize_runpod_webhook_url(env("RUNPOD_DEPLOY_WEBHOOK_URL"))
    if not webhook:
        return 2

    api_key = env("RUNPOD_API_KEY")

    payload = {
        "action": "deploy",
        "status": "requested",
        "image": env("IMAGE_URI") or env("IMAGE_LATEST"),
        "image_latest": env("IMAGE_LATEST"),
        "sha": env("GITHUB_SHA"),
        "repository": env("GITHUB_REPOSITORY"),
        "branch": env("GITHUB_REF_NAME"),
    }

    webhook = add_api_key_query(webhook, api_key)
    print(f"Triggering RunPod deploy webhook: {webhook}")
    try:
        headers = {}
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"
        response = post_json(webhook, payload, headers=headers)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="ignore")
        print(f"Webhook HTTP error: {exc.code} {body}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"Webhook request failed: {exc}", file=sys.stderr)
        return 1

    print("Webhook trigger response:")
    print(json.dumps(response, indent=2, sort_keys=True))
    return 0


def trigger_graphql() -> int:
    api_key = env("RUNPOD_API_KEY")
    mutation = env("RUNPOD_GRAPHQL_MUTATION")
    if not api_key or not mutation:
        return 2

    variables_raw = env("RUNPOD_GRAPHQL_VARIABLES_JSON", "{}")
    try:
        variables = json.loads(variables_raw)
    except Exception as exc:
        print(f"RUNPOD_GRAPHQL_VARIABLES_JSON is invalid JSON: {exc}", file=sys.stderr)
        return 1

    variables.setdefault("imageName", env("IMAGE_URI") or env("IMAGE_LATEST"))
    variables.setdefault("image", env("IMAGE_URI") or env("IMAGE_LATEST"))
    variables.setdefault("imageUri", env("IMAGE_URI") or env("IMAGE_LATEST"))
    variables.setdefault("sha", env("GITHUB_SHA"))

    payload = {
        "query": mutation,
        "variables": variables,
    }

    url = f"https://api.runpod.io/graphql?api_key={api_key}"
    print("Triggering RunPod GraphQL mutation")
    try:
        response = post_json(url, payload, headers={})
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="ignore")
        print(f"GraphQL HTTP error: {exc.code} {body}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"GraphQL request failed: {exc}", file=sys.stderr)
        return 1

    if response.get("errors"):
        print("RunPod GraphQL returned errors:", file=sys.stderr)
        print(json.dumps(response, indent=2, sort_keys=True), file=sys.stderr)
        return 1

    print("RunPod GraphQL response:")
    print(json.dumps(response, indent=2, sort_keys=True))
    return 0


def main() -> int:
    webhook_result = trigger_webhook()
    if webhook_result == 0:
        return 0

    graphql_result = trigger_graphql()
    if graphql_result == 0:
        return 0

    if webhook_result == 2 and graphql_result == 2:
        print(
            "No RunPod deploy target configured. Set either RUNPOD_DEPLOY_WEBHOOK_URL or both RUNPOD_API_KEY and RUNPOD_GRAPHQL_MUTATION.",
            file=sys.stderr,
        )
        return 1

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
