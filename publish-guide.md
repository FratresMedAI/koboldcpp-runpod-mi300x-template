# RunPod Publish Guide for KoboldCPP MI300X

This guide explains how to build, publish, and promote the KoboldCPP RunPod MI300X template so it can be indexed by RunPod Hub and qualify for revenue sharing.

## 1) Prep the repository

Make sure the repo contains these files:

- `Dockerfile`
- `README.md`
- `handler.py`
- `.runpod/hub.json`
- `.runpod/tests.json`
- `entrypoint.sh`
- `health-check.sh`
- `auto-patch.sh`
- `gpu-detect.sh`
- `models-download.sh`
- `.dockerignore`

## 2) Build the Docker image

Use the exact base image from this repository and build for Linux AMD64.

```bash
docker buildx build \
  --platform linux/amd64 \
  -t yourdockerhubuser/koboldcpp-runpod-mi300x:latest \
  --push \
  .
```

If you use GitHub Container Registry instead:

```bash
docker buildx build \
  --platform linux/amd64 \
  -t ghcr.io/yourorg/koboldcpp-runpod-mi300x:latest \
  --push \
  .
```

## 3) Create the public RunPod template

1. Open the RunPod console.
2. Go to **Templates**.
3. Click **New Template**.
4. Set the template image to your pushed container image.
5. Select the **AMD** category.
6. Mark the template **Public**.
7. Set the volume mount path to `/workspace`.
8. Set the primary port to `5001/http`.
9. Add the health port `8080/http`.
10. Paste the README content from this repository.
11. Save the template.

## 4) Publish the repo to RunPod Hub

1. Go to the **Hub** page in the RunPod console.
2. Click **Get Started** under Add your repo.
3. Paste your GitHub repository URL.
4. Make sure `hub.json` and `tests.json` are in `.runpod/`.
5. Ensure `README.md` and `handler.py` exist in the repo root or `.runpod/`.
6. Create a GitHub release; Hub indexes releases, not commits.
7. Wait for Hub review and approval.

## 5) Recommended template settings

- **Runs on:** GPU
- **Category:** AMD
- **Volume mount path:** `/workspace`
- **Container disk:** keep it modest
- **Ports:** `5001/http`, `8080/http`
- **Backend:** `auto` or `amd`
- **Preset:** `balanced`

## 6) Optional Serverless conversion

RunPod’s Hub supports conversion to load-balanced serverless listings.

- Set `"endpointType": "LB"` in `hub.json`.
- Keep `handler.py` working.
- Create or update your Hub listing.
- Deploy as a Serverless endpoint if you want autoscaling and API traffic.

## 7) Validation checklist before publishing

- The container starts on an AMD MI300X pod.
- `/health` responds on port `8080`.
- KoboldCPP listens on port `5001`.
- The runtime logs show backend detection and release checks.
- `/workspace` is used for models and persistent data.
- No large model files are baked into the image.

## 8) Revenue share notes

Once approved on RunPod Hub, the repository can earn credits automatically from user compute usage.

- Keep the repo public.
- Keep the README clear and polished.
- Maintain the template and update it when upstream KoboldCPP changes.
- Provide a helpful release history.

## 9) Suggested release flow

1. Merge your changes.
2. Bump the GitHub release tag.
3. Push the Docker image.
4. Update the Hub listing if needed.
5. Verify the template still boots on MI300X.

## 10) What to tell the community

- It fixes the AMD selection problem.
- It works on MI300X.
- It falls back to NVIDIA when appropriate.
- It auto-heals.
- It downloads starter models automatically.
- It is the easiest way to start KoboldCPP on RunPod.
